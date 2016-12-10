/* Copyright 2016 NVIDIA Corporation
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

#include <cstdio>

#include "snap_types.h"
#include "accessor.h"

using namespace LegionRuntime::Accessor;

// Some bounds for use of GPU kernels, can be modified easily
// Be careful about memory usage
#define MAX_ANGLES  1024
#define MAX_X_CHUNK 16
#define MAX_Y_CHUNK 16

// If you change MAX_CTA you should also adjust the mapper
// to properly chunk the sweeps for the number of buffers
#define MAX_CTA      32 // Only GP100 has more than 32 concurrent kernels

// We'll dynamically allocate the CTA chunks
__device__ unsigned available_chunks[MAX_CTA];
// Create the planes and pencils for doing the sweeps
__device__ double yflux_pencils[MAX_CTA][MAX_X_CHUNK][MAX_ANGLES];
__device__ double zflux_planes[MAX_CTA][MAX_Y_CHUNK][MAX_Y_CHUNK][MAX_ANGLES];

// Don't use the __constant__ qualifier here!
// Each thread in a warp will be indexing on
// a per angle basis and we don't want replays
// when they don't all hit the same constant index
__device__ double device_ec[8/*corners*/*4/*moments*/*MAX_ANGLES];
__device__ double device_mu[MAX_ANGLES];
__device__ double device_eta[MAX_ANGLES];
__device__ double device_xi[MAX_ANGLES];
__device__ double device_w[MAX_ANGLES];

__host__
void initialize_gpu_context(const double *ec_h, const double *mu_h,
                            const double *eta_h, const double *xi_h,
                            const double *w_h, const int num_angles,
                            const int num_moments, const int num_octants,
                            const int nx_per_chunk, const int ny_per_chunk)
{
  // Check the bounds first
  if (num_angles > MAX_ANGLES)
    printf("ERROR: adjust MAX_ANGLES in gpu_sweep.cu to %d", num_angles);
  assert(num_angles <= MAX_ANGLES);
  if (nx_per_chunk > MAX_X_CHUNK)
    printf("ERROR: adjust MAX_X_CHUNK in gpu_sweep.cu to %d", nx_per_chunk);
  assert(nx_per_chunk <= MAX_X_CHUNK);
  if (ny_per_chunk > MAX_Y_CHUNK)
    printf("ERROR: adjust MAX_Y_CHUNK in gpu_sweep.cu to %d", ny_per_chunk);
  assert(ny_per_chunk <= MAX_Y_CHUNK);
  
  // Set all the available chunks to 1 indicating that they are all available
  unsigned available[MAX_CTA];
  for (int i = 0; i < MAX_CTA; i++)
    available[i] = 1;
  cudaMemcpyToSymbol(available_chunks, available, MAX_CTA * sizeof(unsigned));
  cudaMemcpyToSymbol(device_ec, ec_h, 
                     num_angles * num_moments * num_octants * sizeof(double));
  cudaMemcpyToSymbol(device_mu, mu_h, num_angles * sizeof(double));
  cudaMemcpyToSymbol(device_eta, eta_h, num_angles * sizeof(double));
  cudaMemcpyToSymbol(device_xi, xi_h, num_angles * sizeof(double));
  cudaMemcpyToSymbol(device_w, w_h, num_angles * sizeof(double));
}

__device__ __forceinline__
ByteOffset operator*(const ByteOffset offsets[3], const Point<3> &point)
{
  return (offsets[0] * point.x[0] + offsets[1] * point.x[1] + offsets[2] * point.x[2]);
}

__device__ __forceinline__
void atomicAdd(double *ptr, double value)
{
  unsigned long long int* address_as_ull = (unsigned long long int*)ptr; 
  unsigned long long int old = *address_as_ull, assumed; 
  do { 
    assumed = old; 
    old = atomicCAS(address_as_ull, assumed, 
        __double_as_longlong(value + __longlong_as_double(assumed))); 
  } while (assumed != old);
}

__device__ __forceinline__
double angle_read(const double *ptr, const ByteOffset offset[3],
                  const Point<3> &point, int ang)
{
  ptr += (offset * point);
  ptr += ang * blockDim.x + threadIdx.x;
  double result;
  asm volatile("ld.global.cs.f64 %0, [%1];" : "=d"(result) : "l"(ptr) : "memory");
  return result;
}

__device__ __forceinline__
void angle_write(double *ptr, const ByteOffset offset[3],
                 const Point<3> &point, int ang, double val)
{
  ptr += (offset * point);
  ptr += ang * blockDim.x + threadIdx.x;
  asm volatile("st.global.cs.f64 [%0], %1;" : : "l"(ptr), "d"(val) : "memory");
}

template<int THR_ANGLES>
__global__
void gpu_time_dependent_sweep_with_fixup(const Point<3> origin, 
                                         const MomentQuad *qtot_ptr,
                                               double     *flux_ptr,
                                               MomentQuad *fluxm_ptr,
                                         const double     *dinv_ptr,
                                         const double     *time_flux_in_ptr,
                                               double     *time_flux_out_ptr,
                                         const double     *t_xs_ptr,
                                               double     *ghostx_out_ptr,
                                               double     *ghosty_out_ptr,
                                               double     *ghostz_out_ptr,
                                         const double     *qim_ptr,
                                         const double     *ghostx_in_ptr,
                                         const double     *ghosty_in_ptr,
                                         const double     *ghostz_in_ptr,
                                         const ByteOffset qtot_offsets[3],
                                         const ByteOffset flux_offsets[3],
                                         const ByteOffset fluxm_offsets[3],
                                         const ByteOffset dinv_offsets[3],
                                         const ByteOffset time_flux_in_offsets[3],
                                         const ByteOffset time_flux_out_offsets[3],
                                         const ByteOffset t_xs_offsets[3],
                                         const ByteOffset ghostx_out_offsets[3],
                                         const ByteOffset ghosty_out_offsets[3],
                                         const ByteOffset ghostz_out_offsets[3],
                                         const ByteOffset qim_offsets[3],
                                         const ByteOffset ghostx_in_offsets[3],
                                         const ByteOffset ghosty_in_offsets[3],
                                         const ByteOffset ghostz_in_offsets[3],
                                         const int x_range, const int y_range, 
                                         const int z_range, const int corner,
                                         const bool stride_x_positive,
                                         const bool stride_y_positive,
                                         const bool stride_z_positive,
                                         const bool mms_source, 
                                         const int num_moments, 
                                         const double hi, const double hj,
                                         const double hk, const double vdelt)
{
  __shared__ int int_trampoline[32];
  __shared__ double double_trampoline[32];

  double psi[THR_ANGLES];
  double pc[THR_ANGLES];
  double psii[THR_ANGLES];
  double psij[THR_ANGLES];
  double psik[THR_ANGLES];
  double hv_x[THR_ANGLES];
  double hv_y[THR_ANGLES];
  double hv_z[THR_ANGLES];
  double hv_t[THR_ANGLES];
  double fx_hv_x[THR_ANGLES];
  double fx_hv_y[THR_ANGLES];
  double fx_hv_z[THR_ANGLES];
  double fx_hv_t[THR_ANGLES];
  double time_flux_in[THR_ANGLES];

  const int num_angles = THR_ANGLES * blockDim.x;
  const int corner_offset = corner * num_angles * num_moments; 

  unsigned laneid;
  asm volatile("mov.u32 %0, %laneid;" : "=r"(laneid) : );
  unsigned warpid;
  asm volatile("mov.u32 %0, %warpid;" : "=r"(warpid) : );

  // Get a chunk for this CTA
  if ((warpid == 0) && (laneid == 0)) {
    // Start at our SM ID to avoid contention
    int smid;
    asm volatile("mov.u32 %0, %smid;" : "=r"(smid) : );
    int chunk = -1;
    while (chunk < 0) {
      #pragma unroll
      for (int i = 0; i < MAX_CTA; i++) {
        int offset = (smid + i) % MAX_CTA;
        if (atomicDec(available_chunks+offset, 0) == 1) {
          chunk = offset;
          break;
        }
      }
    }
    int_trampoline[0] = chunk;
  }
  __syncthreads();
  const int cta_chunk = int_trampoline[0];
  __syncthreads();

  const double tolr = 1.0e-12;

  for (int z = 0; z < z_range; z++) {
    for (int y = 0; y < y_range; y++) {
      for (int x = 0; x < x_range; x++) {
        // Figure out the local point that we are working on    
        Point<3> local_point = origin;
        if (stride_x_positive)
          local_point.x[0] += x;
        else
          local_point.x[0] -= x;
        if (stride_y_positive)
          local_point.x[1] += y;
        else
          local_point.x[1] -= y;
        if (stride_z_positive)
          local_point.x[2] += z;
        else
          local_point.x[2] -= z;

        // Compute the angular source
        MomentQuad quad = *(qtot_ptr + qtot_offsets * local_point);
        #pragma unroll
        for (int ang = 0; ang < THR_ANGLES; ang++)
          psi[ang] = quad[0];
        if (num_moments > 1) {
          for (int l = 1; l < num_moments; l++) {
            const int moment_offset = corner_offset + l * num_angles;
            #pragma unroll
            for (int ang = 0; ang < THR_ANGLES; ang++) {
              psi[ang] += device_ec[moment_offset+ang*blockDim.x+threadIdx.x] * quad[l];
            }
          }
        }

        // If we're doing MMS
        if (mms_source) {
          #pragma unroll
          for (int ang = 0; ang < THR_ANGLES; ang++)
            psi[ang] += angle_read(qim_ptr, qim_offsets, local_point, ang);
        }

        // Compute the initial solution
        #pragma unroll
        for (int ang = 0; ang < THR_ANGLES; ang++)
          pc[ang] = psi[ang];
        // X ghost cells
        if (stride_x_positive) {
          // reading from x-1 
          Point<3> ghost_point = local_point;
          ghost_point.x[0] -= 1;
          if (x == 0) {
            // Ghost cell array
            #pragma unroll 
            for (int ang = 0; ang < THR_ANGLES; ang++)
              psii[ang] = angle_read(ghostx_in_ptr, ghostx_in_offsets, 
                                     ghost_point, ang);
          } 
          // Else nothing: psii already contains next flux
        } else {
          // reading from x+1
          Point<3> ghost_point = local_point;
          ghost_point.x[0] += 1;
          // Local coordinates here
          if (x == 0) {
            // Ghost cell array
            #pragma unroll
            for (int ang = 0; ang < THR_ANGLES; ang++)
              psii[ang] = angle_read(ghostx_in_ptr, ghostx_in_offsets, 
                                     ghost_point, ang);
          }
          // Else nothing: psii already contains next flux
        }
        #pragma unroll
        for (int ang = 0; ang < THR_ANGLES; ang++)
          pc[ang] += psii[ang] * device_mu[ang*blockDim.x + threadIdx.x] * hi;
        // Y ghost cells
        if (stride_y_positive) {
          // reading from y-1
          Point<3> ghost_point = local_point;
          ghost_point.x[1] -= 1;
          if (y == 0) {
            // Ghost cell array
            #pragma unroll
            for (int ang = 0; ang < THR_ANGLES; ang++)
              psij[ang] = angle_read(ghosty_in_ptr, ghosty_in_offsets,
                                     ghost_point, ang);
          } else {
            // Local array
            #pragma unroll
            for (int ang = 0; ang < THR_ANGLES; ang++)
              psij[ang] = yflux_pencils[cta_chunk][x][ang*blockDim.x + threadIdx.x];
          }
        } else {
          // reading from y+1
          Point<3> ghost_point = local_point;
          ghost_point.x[1] += 1;
          // Local coordinates here
          if (y == 0) {
            // Ghost cell array
            #pragma unroll
            for (int ang = 0; ang < THR_ANGLES; ang++)
              psij[ang] = angle_read(ghosty_in_ptr, ghosty_in_offsets,
                                     ghost_point, ang);
          } else {
            // Local array
            #pragma unroll
            for (int ang = 0; ang < THR_ANGLES; ang++)
              psij[ang] = yflux_pencils[cta_chunk][x][ang*blockDim.x + threadIdx.x];
          }
        }
        #pragma unroll
        for (int ang = 0; ang < THR_ANGLES; ang++)
          pc[ang] += psij[ang] * device_eta[ang * blockDim.x + threadIdx.x] * hj;
        // Z ghost cells
        if (stride_z_positive) {
          // reading from z-1
          Point<3> ghost_point = local_point;
          ghost_point.x[2] -= 1;
          if (z == 0) {
            // Ghost cell array
            #pragma unroll
            for (int ang = 0; ang < THR_ANGLES; ang++)
              psik[ang] = angle_read(ghostz_in_ptr, ghostz_in_offsets,
                                     ghost_point, ang);
          } else {
            // Local array
            #pragma unroll
            for (int ang = 0; ang < THR_ANGLES; ang++)
              psik[ang] = zflux_planes[cta_chunk][y][x][ang*blockDim.x + threadIdx.x];
          }
        } else {
          // reading from z+1
          Point<3> ghost_point = local_point;
          ghost_point.x[2] += 1;
          // Local coordinates here
          if (z == 0) {
            // Ghost cell array
            #pragma unroll
            for (int ang = 0; ang < THR_ANGLES; ang++)
              psik[ang] = angle_read(ghostz_in_ptr, ghostz_in_offsets,
                                     ghost_point, ang);
          } else {
            // Local array
            #pragma unroll
            for (int ang = 0; ang < THR_ANGLES; ang++)
              psik[ang] = zflux_planes[cta_chunk][y][x][ang*blockDim.x + threadIdx.x];
          }
        }
        #pragma unroll
        for (int ang = 0; ang < THR_ANGLES; ang++)
          pc[ang] += psik[ang] * device_xi[ang * blockDim.x + threadIdx.x] * hk;

        #pragma unroll
        for (int ang = 0; ang < THR_ANGLES; ang++) {
          time_flux_in[ang] = angle_read(time_flux_in_ptr, time_flux_in_offsets,
                                         local_point, ang);
          pc[ang] += vdelt * time_flux_in[ang];
        }
        
        #pragma unroll
        for (int ang = 0; ang < THR_ANGLES; ang++) {
          double dinv = angle_read(dinv_ptr, dinv_offsets, local_point, ang);
          pc[ang] *= dinv;
        }

        // DO THE FIXUP
        #pragma unroll
        for (int ang = 0; ang < THR_ANGLES; ang++)
          hv_x[ang] = 1.0;
        #pragma unroll
        for (int ang = 0; ang < THR_ANGLES; ang++)
          hv_y[ang] = 1.0;
        #pragma unroll
        for (int ang = 0; ang < THR_ANGLES; ang++)
          hv_z[ang] = 1.0;
        #pragma unroll
        for (int ang = 0; ang < THR_ANGLES; ang++)
          hv_t[ang] = 1.0;

        const double t_xs = *(t_xs_ptr + t_xs_offsets * local_point);
        int old_negative_fluxes = 0;
        while (true) {
          unsigned negative_fluxes = 0;
          // Figure out how many negative fluxes we have
          #pragma unroll
          for (int ang = 0; ang < THR_ANGLES; ang++) {
            fx_hv_x[ang] = 2.0 * pc[ang] - psii[ang];
            if (fx_hv_x[ang] < 0.0) {
              hv_x[ang] = 0.0;
              negative_fluxes++;
            }
          }
          #pragma unroll
          for (int ang = 0; ang < THR_ANGLES; ang++) {
            fx_hv_y[ang] = 2.0 * pc[ang] - psij[ang];
            if (fx_hv_y[ang] < 0.0) {
              hv_y[ang] = 0.0;
              negative_fluxes++;
            }
          }
          #pragma unroll
          for (int ang = 0; ang < THR_ANGLES; ang++) {
            fx_hv_z[ang] = 2.0 * pc[ang] - psik[ang];
            if (fx_hv_z[ang] < 0.0) {
              hv_z[ang] = 0.0;
              negative_fluxes++;
            }
          }
          #pragma unroll
          for (int ang = 0; ang < THR_ANGLES; ang++) {
            fx_hv_t[ang] = 2.0 * pc[ang] - time_flux_in[ang];
            if (fx_hv_t[ang] < 0.0) {
              hv_t[ang] = 0.0;
              negative_fluxes++;
            }
          }
          // CTA-wide reduction
          #pragma unroll
          for (int i = 16; i >= 1; i /= 2)
            negative_fluxes += __shfl_xor(negative_fluxes, i, 32);
          // Initialize
          if (warpid == 0)
            int_trampoline[laneid] = 0;
          __syncthreads();
          if (laneid == 0)
            int_trampoline[warpid] = negative_fluxes;
          __syncthreads();
          negative_fluxes = int_trampoline[laneid];
          #pragma unroll
          for (int i = 16; i >= 1; i /= 2)
            negative_fluxes += __shfl_xor(negative_fluxes, i, 32);
          // All threads have the same negative flux count now
          if (negative_fluxes == old_negative_fluxes)
            break;
          old_negative_fluxes = negative_fluxes;
          #pragma unroll
          for (int ang = 0; ang < THR_ANGLES; ang++) {
            pc[ang] = psi[ang] + 0.5 * (
              psii[ang] * device_mu[ang*blockDim.x + threadIdx.x] * hi * (1.0 + hv_x[ang]) +
              psij[ang] * device_eta[ang*blockDim.x + threadIdx.x] * hj * (1.0 + hv_y[ang]) +
              psik[ang] * device_xi[ang*blockDim.x + threadIdx.x] * hk * (1.0 + hv_z[ang]) +
              time_flux_in[ang] * vdelt * (1.0 + hv_t[ang]) );
            double den = (pc[ang] <= 0.0) ? 0.0 : (t_xs + 
                device_mu[ang*blockDim.x + threadIdx.x] * hi * hv_x[ang] + 
                device_eta[ang*blockDim.x + threadIdx.x] * hj * hv_y[ang] + 
                device_xi[ang*blockDim.x + threadIdx.x] * hk * hv_z[ang] +
                vdelt * hv_t[ang]);
            if (den < tolr)
              pc[ang] = 0.0;
            else
              pc[ang] /= den;
          }
        }
        // Fixup done so compute the update values
        #pragma unroll
        for (int ang = 0; ang < THR_ANGLES; ang++)
          psii[ang] = fx_hv_x[ang] * hv_x[ang];
        #pragma unroll
        for (int ang = 0; ang < THR_ANGLES; ang++)
          psij[ang] = fx_hv_y[ang] * hv_y[ang];
        #pragma unroll
        for (int ang = 0; ang < THR_ANGLES; ang++)
          psik[ang] = fx_hv_z[ang] * hv_z[ang];
        #pragma unroll
        for (int ang = 0; ang < THR_ANGLES; ang++) {
          double time_flux_out = fx_hv_t[ang] * hv_t[ang];
          angle_write(time_flux_out_ptr, time_flux_out_offsets,
                      local_point, ang, time_flux_out);
        }
        // Write out the ghost regions
        // X ghost
        if (x == (x_range - 1)) {
          #pragma unroll
          for (int ang = 0; ang < THR_ANGLES; ang++)
            angle_write(ghostx_out_ptr, ghostx_out_offsets,
                        local_point, ang, psii[ang]);
        }
        // Y ghost
        if (y == (y_range - 1)) {
          #pragma unroll
          for (int ang = 0; ang < THR_ANGLES; ang++)
            angle_write(ghosty_out_ptr, ghosty_out_offsets,
                        local_point, ang, psij[ang]);
        } else {
          // Write to the pencil
          #pragma unroll
          for (int ang = 0; ang < THR_ANGLES; ang++)
            yflux_pencils[cta_chunk][x][ang*blockDim.x + threadIdx.x] = psij[ang];
        }
        // Z ghost
        if (z == (z_range - 1)) {
          #pragma unroll
          for (int ang = 0; ang < THR_ANGLES; ang++)
            angle_write(ghostz_out_ptr, ghostz_out_offsets,
                        local_point, ang, psik[ang]);
        } else {
          #pragma unroll
          for (int ang = 0; ang < THR_ANGLES; ang++)
            zflux_planes[cta_chunk][y][x][ang*blockDim.x + threadIdx.x] = psik[ang];
        }
        // Finally we apply reductions to the flux moments
        double total = 0.0;  
        #pragma unroll
        for (int ang = 0; ang < THR_ANGLES; ang++) {
          psi[ang] = device_w[ang * blockDim.x + threadIdx.x] * pc[ang];
          total += psi[ang];
        }
        // CTA-wide reduction to one warp and then down to one thread
        #pragma unroll
        for (int i = 16; i >= 1; i /= 2) {
          int hi_part = __shfl_xor(__double2hiint(total), i, 32);
          int lo_part = __shfl_xor(__double2loint(total), i, 32);
          total += __hiloint2double(hi_part,lo_part); 
        }
        if (warpid == 0)
          double_trampoline[laneid] = 0.0;
        __syncthreads();
        if (laneid == 0)
          double_trampoline[warpid] = total;
        __syncthreads();
        if (warpid == 0) {
          total = double_trampoline[laneid];
          #pragma unroll
          for (int i = 16; i >= 1; i /= 2) {
            int hi_part = __shfl_xor(__double2hiint(total), i, 32);
            int lo_part = __shfl_xor(__double2loint(total), i, 32);
            total += __hiloint2double(hi_part,lo_part); 
          }
          // Do the reduction
          if (laneid == 0) {
            double *local_flux = flux_ptr + flux_offsets * local_point;
            atomicAdd(local_flux, total);
          }
        }
        if (num_moments > 1) {
          for (int l = 1; l < num_moments; l++) {
            const int offset = l * num_angles + corner * num_angles * num_moments;
            total = 0.0;
            #pragma unroll
            for (int ang = 0; ang < THR_ANGLES; ang++)
              total += device_ec[offset + ang] * psi[ang];
            __syncthreads();
            if (warpid == 0)
              double_trampoline[laneid] = 0.0;
            __syncthreads();
            if (laneid == 0)
              double_trampoline[warpid] = total;
            __syncthreads();
            if (warpid == 0)
              total = double_trampoline[laneid];
            #pragma unroll
            for (int i = 16; i >= 1; i /= 2) {
              int hi_part = __shfl_xor(__double2hiint(total), i, 32);
              int lo_part = __shfl_xor(__double2loint(total), i, 32);
              total += __hiloint2double(hi_part,lo_part); 
            }
            if (laneid == 0) {
              double *local_fluxm = (double*)(fluxm_ptr + fluxm_offsets * local_point);
              local_fluxm += (l-1);
              atomicAdd(local_fluxm, total);
            }
          }
        }
      }
    }
  }
  // Release our CTA chunk back to the pool
  atomicInc(available_chunks+cta_chunk, 1);
}

template<int THR_ANGLES>
__global__
void gpu_time_dependent_sweep_without_fixup(const Point<3> origin, 
                                         const MomentQuad *qtot_ptr,
                                               double     *flux_ptr,
                                               MomentQuad *fluxm_ptr,
                                         const double     *dinv_ptr,
                                         const double     *time_flux_in_ptr,
                                               double     *time_flux_out_ptr,
                                               double     *ghostx_out_ptr,
                                               double     *ghosty_out_ptr,
                                               double     *ghostz_out_ptr,
                                         const double     *qim_ptr,
                                         const double     *ghostx_in_ptr,
                                         const double     *ghosty_in_ptr,
                                         const double     *ghostz_in_ptr,
                                         const ByteOffset qtot_offsets[3],
                                         const ByteOffset flux_offsets[3],
                                         const ByteOffset fluxm_offsets[3],
                                         const ByteOffset dinv_offsets[3],
                                         const ByteOffset time_flux_in_offsets[3],
                                         const ByteOffset time_flux_out_offsets[3],
                                         const ByteOffset ghostx_out_offsets[3],
                                         const ByteOffset ghosty_out_offsets[3],
                                         const ByteOffset ghostz_out_offsets[3],
                                         const ByteOffset qim_offsets[3],
                                         const ByteOffset ghostx_in_offsets[3],
                                         const ByteOffset ghosty_in_offsets[3],
                                         const ByteOffset ghostz_in_offsets[3],
                                         const int x_range, const int y_range, 
                                         const int z_range, const int corner,
                                         const bool stride_x_positive,
                                         const bool stride_y_positive,
                                         const bool stride_z_positive,
                                         const bool mms_source, 
                                         const int num_moments, 
                                         const double hi, const double hj,
                                         const double hk, const double vdelt)
{
  __shared__ int int_trampoline;
  __shared__ double double_trampoline[32];

  double psi[THR_ANGLES];
  double pc[THR_ANGLES];
  double psii[THR_ANGLES];
  double psij[THR_ANGLES];
  double psik[THR_ANGLES];
  double time_flux_in[THR_ANGLES];

  const int num_angles = THR_ANGLES * blockDim.x;
  const int corner_offset = corner * num_angles * num_moments; 

  unsigned laneid;
  asm volatile("mov.u32 %0, %laneid;" : "=r"(laneid) : );
  unsigned warpid;
  asm volatile("mov.u32 %0, %warpid;" : "=r"(warpid) : );

  // Get a chunk for this CTA
  if ((warpid == 0) && (laneid == 0)) {
    // Start at our SM ID to avoid contention
    int smid;
    asm volatile("mov.u32 %0, %smid;" : "=r"(smid) : );
    int chunk = -1;
    while (chunk < 0) {
      #pragma unroll
      for (int i = 0; i < MAX_CTA; i++) {
        int offset = (smid + i) % MAX_CTA;
        if (atomicDec(available_chunks+offset, 0) == 1) {
          chunk = offset;
          break;
        }
      }
    }
    int_trampoline = chunk;
  }
  __syncthreads();
  const int cta_chunk = int_trampoline;
  __syncthreads();

  for (int z = 0; z < z_range; z++) {
    for (int y = 0; y < y_range; y++) {
      for (int x = 0; x < x_range; x++) {
        // Figure out the local point that we are working on    
        Point<3> local_point = origin;
        if (stride_x_positive)
          local_point.x[0] += x;
        else
          local_point.x[0] -= x;
        if (stride_y_positive)
          local_point.x[1] += y;
        else
          local_point.x[1] -= y;
        if (stride_z_positive)
          local_point.x[2] += z;
        else
          local_point.x[2] -= z;

        // Compute the angular source
        MomentQuad quad = *(qtot_ptr + qtot_offsets * local_point);
        #pragma unroll
        for (int ang = 0; ang < THR_ANGLES; ang++)
          psi[ang] = quad[0];
        if (num_moments > 1) {
          for (int l = 1; l < num_moments; l++) {
            const int moment_offset = corner_offset + l * num_angles;
            #pragma unroll
            for (int ang = 0; ang < THR_ANGLES; ang++) {
              psi[ang] += device_ec[moment_offset+ang*blockDim.x+threadIdx.x] * quad[l];
            }
          }
        }

        // If we're doing MMS
        if (mms_source) {
          #pragma unroll
          for (int ang = 0; ang < THR_ANGLES; ang++)
            psi[ang] += angle_read(qim_ptr, qim_offsets, local_point, ang);
        }

        // Compute the initial solution
        #pragma unroll
        for (int ang = 0; ang < THR_ANGLES; ang++)
          pc[ang] = psi[ang];
        // X ghost cells
        if (stride_x_positive) {
          // reading from x-1 
          Point<3> ghost_point = local_point;
          ghost_point.x[0] -= 1;
          if (x == 0) {
            // Ghost cell array
            #pragma unroll 
            for (int ang = 0; ang < THR_ANGLES; ang++)
              psii[ang] = angle_read(ghostx_in_ptr, ghostx_in_offsets,
                                     ghost_point, ang);
          } 
          // Else nothing: psii already contains next flux
        } else {
          // reading from x+1
          Point<3> ghost_point = local_point;
          ghost_point.x[0] += 1;
          // Local coordinates here
          if (x == 0) {
            // Ghost cell array
            #pragma unroll
            for (int ang = 0; ang < THR_ANGLES; ang++)
              psii[ang] = angle_read(ghostx_in_ptr, ghostx_in_offsets,
                                     ghost_point, ang);
          }
          // Else nothing: psii already contains next flux
        }
        #pragma unroll
        for (int ang = 0; ang < THR_ANGLES; ang++)
          pc[ang] += psii[ang] * device_mu[ang*blockDim.x + threadIdx.x] * hi;
        // Y ghost cells
        if (stride_y_positive) {
          // reading from y-1
          Point<3> ghost_point = local_point;
          ghost_point.x[1] -= 1;
          if (y == 0) {
            // Ghost cell array
            #pragma unroll
            for (int ang = 0; ang < THR_ANGLES; ang++)
              psij[ang] = angle_read(ghosty_in_ptr, ghosty_in_offsets,
                                     ghost_point, ang);
          } else {
            // Local array
            #pragma unroll
            for (int ang = 0; ang < THR_ANGLES; ang++)
              psij[ang] = yflux_pencils[cta_chunk][x][ang*blockDim.x + threadIdx.x];
          }
        } else {
          // reading from y+1
          Point<3> ghost_point = local_point;
          ghost_point.x[1] += 1;
          // Local coordinates here
          if (y == 0) {
            // Ghost cell array
            #pragma unroll
            for (int ang = 0; ang < THR_ANGLES; ang++)
              psij[ang] = angle_read(ghosty_in_ptr, ghosty_in_offsets,
                                     ghost_point, ang);
          } else {
            // Local array
            #pragma unroll
            for (int ang = 0; ang < THR_ANGLES; ang++)
              psij[ang] = yflux_pencils[cta_chunk][x][ang*blockDim.x + threadIdx.x];
          }
        }
        #pragma unroll
        for (int ang = 0; ang < THR_ANGLES; ang++)
          pc[ang] += psij[ang] * device_eta[ang * blockDim.x + threadIdx.x] * hj;
        // Z ghost cells
        if (stride_z_positive) {
          // reading from z-1
          Point<3> ghost_point = local_point;
          ghost_point.x[2] -= 1;
          if (z == 0) {
            // Ghost cell array
            #pragma unroll
            for (int ang = 0; ang < THR_ANGLES; ang++)
              psik[ang] = angle_read(ghostz_in_ptr, ghostz_in_offsets,
                                     ghost_point, ang);
          } else {
            // Local array
            #pragma unroll
            for (int ang = 0; ang < THR_ANGLES; ang++)
              psik[ang] = zflux_planes[cta_chunk][y][x][ang*blockDim.x + threadIdx.x];
          }
        } else {
          // reading from z+1
          Point<3> ghost_point = local_point;
          ghost_point.x[2] += 1;
          // Local coordinates here
          if (z == 0) {
            // Ghost cell array
            #pragma unroll
            for (int ang = 0; ang < THR_ANGLES; ang++)
              psik[ang] = angle_read(ghostz_in_ptr, ghostz_in_offsets,
                                     ghost_point, ang);
          } else {
            // Local array
            #pragma unroll
            for (int ang = 0; ang < THR_ANGLES; ang++)
              psik[ang] = zflux_planes[cta_chunk][y][x][ang*blockDim.x + threadIdx.x];
          }
        }
        #pragma unroll
        for (int ang = 0; ang < THR_ANGLES; ang++)
          pc[ang] += psik[ang] * device_xi[ang * blockDim.x + threadIdx.x] * hk;

        #pragma unroll
        for (int ang = 0; ang < THR_ANGLES; ang++) {
          time_flux_in[ang] = angle_read(time_flux_in_ptr, time_flux_in_offsets,
                                         local_point, ang);
          pc[ang] += vdelt * time_flux_in[ang];
        }
        
        #pragma unroll
        for (int ang = 0; ang < THR_ANGLES; ang++) {
          double dinv = angle_read(dinv_ptr, dinv_offsets, local_point, ang);
          pc[ang] *= dinv;
        }

        // NO FIXUP
        #pragma unroll
        for (int ang = 0; ang < THR_ANGLES; ang++)
          psii[ang] = 2.0 * pc[ang] - psii[ang];
        #pragma unroll
        for (int ang = 0; ang < THR_ANGLES; ang++)
          psij[ang] = 2.0 * pc[ang] - psij[ang];
        #pragma unroll
        for (int ang = 0; ang < THR_ANGLES; ang++)
          psik[ang] = 2.0 * pc[ang] - psik[ang];

        #pragma unroll
        for (int ang = 0; ang < THR_ANGLES; ang++) {
          double time_flux_out = 2.0 * pc[ang] - time_flux_in[ang];
          angle_write(time_flux_out_ptr, time_flux_out_offsets,
                      local_point, ang, time_flux_out);
        }
        // Write out the ghost regions
        // X ghost
        if (x == (x_range - 1)) {
          #pragma unroll
          for (int ang = 0; ang < THR_ANGLES; ang++)
            angle_write(ghostx_out_ptr, ghostx_out_offsets,
                        local_point, ang, psii[ang]);
        }
        // Y ghost
        if (y == (y_range - 1)) {
          #pragma unroll
          for (int ang = 0; ang < THR_ANGLES; ang++)
            angle_write(ghosty_out_ptr, ghosty_out_offsets,
                        local_point, ang, psij[ang]);
        } else {
          // Write to the pencil
          #pragma unroll
          for (int ang = 0; ang < THR_ANGLES; ang++)
            yflux_pencils[cta_chunk][x][ang*blockDim.x + threadIdx.x] = psij[ang];
        }
        // Z ghost
        if (z == (z_range - 1)) {
          #pragma unroll
          for (int ang = 0; ang < THR_ANGLES; ang++)
            angle_write(ghostz_out_ptr, ghostz_out_offsets, 
                        local_point, ang, psik[ang]);
        } else {
          #pragma unroll
          for (int ang = 0; ang < THR_ANGLES; ang++)
            zflux_planes[cta_chunk][y][x][ang*blockDim.x + threadIdx.x] = psik[ang];
        }
        // Finally we apply reductions to the flux moments
        double total = 0.0;  
        #pragma unroll
        for (int ang = 0; ang < THR_ANGLES; ang++) {
          psi[ang] = device_w[ang * blockDim.x + threadIdx.x] * pc[ang];
          total += psi[ang];
        }
        // CTA-wide reduction to one warp and then down to one thread
        #pragma unroll
        for (int i = 16; i >= 1; i /= 2) {
          int hi_part = __shfl_xor(__double2hiint(total), i, 32);
          int lo_part = __shfl_xor(__double2loint(total), i, 32);
          total += __hiloint2double(hi_part,lo_part); 
        }
        if (warpid == 0)
          double_trampoline[laneid] = 0.0;
        __syncthreads();
        if (laneid == 0)
          double_trampoline[warpid] = total;
        __syncthreads();
        if (warpid == 0) {
          total = double_trampoline[laneid];
          #pragma unroll
          for (int i = 16; i >= 1; i /= 2) {
            int hi_part = __shfl_xor(__double2hiint(total), i, 32);
            int lo_part = __shfl_xor(__double2loint(total), i, 32);
            total += __hiloint2double(hi_part,lo_part); 
          }
          // Do the reduction
          if (laneid == 0) {
            double *local_flux = flux_ptr + flux_offsets * local_point;
            atomicAdd(local_flux, total);
          }
        }
        if (num_moments > 1) {
          for (int l = 1; l < num_moments; l++) {
            const int offset = l * num_angles + corner * num_angles * num_moments;
            total = 0.0;
            #pragma unroll
            for (int ang = 0; ang < THR_ANGLES; ang++)
              total += device_ec[offset + ang] * psi[ang];
            __syncthreads();
            if (warpid == 0)
              double_trampoline[laneid] = 0.0;
            __syncthreads();
            if (laneid == 0)
              double_trampoline[warpid] = total;
            __syncthreads();
            if (warpid == 0)
              total = double_trampoline[laneid];
            #pragma unroll
            for (int i = 16; i >= 1; i /= 2) {
              int hi_part = __shfl_xor(__double2hiint(total), i, 32);
              int lo_part = __shfl_xor(__double2loint(total), i, 32);
              total += __hiloint2double(hi_part,lo_part); 
            }
            if (laneid == 0) {
              double *local_fluxm = (double*)(fluxm_ptr + fluxm_offsets * local_point);
              local_fluxm += (l-1);
              atomicAdd(local_fluxm, total);
            }
          }
        }
      }
    }
  }
  // Release our CTA chunk back to the pool
  atomicInc(available_chunks+cta_chunk, 1);
}

template<int THR_ANGLES>
__global__
void gpu_time_independent_sweep_with_fixup(const Point<3> origin, 
                                         const MomentQuad *qtot_ptr,
                                               double     *flux_ptr,
                                               MomentQuad *fluxm_ptr,
                                         const double     *dinv_ptr,
                                         const double     *t_xs_ptr,
                                               double     *ghostx_out_ptr,
                                               double     *ghosty_out_ptr,
                                               double     *ghostz_out_ptr,
                                         const double     *qim_ptr,
                                         const double     *ghostx_in_ptr,
                                         const double     *ghosty_in_ptr,
                                         const double     *ghostz_in_ptr,
                                         const ByteOffset qtot_offsets[3],
                                         const ByteOffset flux_offsets[3],
                                         const ByteOffset fluxm_offsets[3],
                                         const ByteOffset dinv_offsets[3],
                                         const ByteOffset t_xs_offsets[3],
                                         const ByteOffset ghostx_out_offsets[3],
                                         const ByteOffset ghosty_out_offsets[3],
                                         const ByteOffset ghostz_out_offsets[3],
                                         const ByteOffset qim_offsets[3],
                                         const ByteOffset ghostx_in_offsets[3],
                                         const ByteOffset ghosty_in_offsets[3],
                                         const ByteOffset ghostz_in_offsets[3],
                                         const int x_range, const int y_range, 
                                         const int z_range, const int corner,
                                         const bool stride_x_positive,
                                         const bool stride_y_positive,
                                         const bool stride_z_positive,
                                         const bool mms_source, 
                                         const int num_moments, 
                                         const double hi, const double hj,
                                         const double hk)
{
  __shared__ int int_trampoline[32];
  __shared__ double double_trampoline[32];

  double psi[THR_ANGLES];
  double pc[THR_ANGLES];
  double psii[THR_ANGLES];
  double psij[THR_ANGLES];
  double psik[THR_ANGLES];
  double hv_x[THR_ANGLES];
  double hv_y[THR_ANGLES];
  double hv_z[THR_ANGLES];
  double fx_hv_x[THR_ANGLES];
  double fx_hv_y[THR_ANGLES];
  double fx_hv_z[THR_ANGLES];

  const int num_angles = THR_ANGLES * blockDim.x;
  const int corner_offset = corner * num_angles * num_moments; 

  unsigned laneid;
  asm volatile("mov.u32 %0, %laneid;" : "=r"(laneid) : );
  unsigned warpid;
  asm volatile("mov.u32 %0, %warpid;" : "=r"(warpid) : );

  // Get a chunk for this CTA
  if ((warpid == 0) && (laneid == 0)) {
    // Start at our SM ID to avoid contention
    int smid;
    asm volatile("mov.u32 %0, %smid;" : "=r"(smid) : );
    int chunk = -1;
    while (chunk < 0) {
      #pragma unroll
      for (int i = 0; i < MAX_CTA; i++) {
        int offset = (smid + i) % MAX_CTA;
        if (atomicDec(available_chunks+offset, 0) == 1) {
          chunk = offset;
          break;
        }
      }
    }
    int_trampoline[0] = chunk;
  }
  __syncthreads();
  const int cta_chunk = int_trampoline[0];
  __syncthreads();

  const double tolr = 1.0e-12;

  for (int z = 0; z < z_range; z++) {
    for (int y = 0; y < y_range; y++) {
      for (int x = 0; x < x_range; x++) {
        // Figure out the local point that we are working on    
        Point<3> local_point = origin;
        if (stride_x_positive)
          local_point.x[0] += x;
        else
          local_point.x[0] -= x;
        if (stride_y_positive)
          local_point.x[1] += y;
        else
          local_point.x[1] -= y;
        if (stride_z_positive)
          local_point.x[2] += z;
        else
          local_point.x[2] -= z;

        // Compute the angular source
        MomentQuad quad = *(qtot_ptr + qtot_offsets * local_point);
        #pragma unroll
        for (int ang = 0; ang < THR_ANGLES; ang++)
          psi[ang] = quad[0];
        if (num_moments > 1) {
          for (int l = 1; l < num_moments; l++) {
            const int moment_offset = corner_offset + l * num_angles;
            #pragma unroll
            for (int ang = 0; ang < THR_ANGLES; ang++) {
              psi[ang] += device_ec[moment_offset+ang*blockDim.x+threadIdx.x] * quad[l];
            }
          }
        }

        // If we're doing MMS
        if (mms_source) {
          #pragma unroll
          for (int ang = 0; ang < THR_ANGLES; ang++)
            psi[ang] += angle_read(qim_ptr, qim_offsets, local_point, ang);
        }

        // Compute the initial solution
        #pragma unroll
        for (int ang = 0; ang < THR_ANGLES; ang++)
          pc[ang] = psi[ang];
        // X ghost cells
        if (stride_x_positive) {
          // reading from x-1 
          Point<3> ghost_point = local_point;
          ghost_point.x[0] -= 1;
          if (x == 0) {
            // Ghost cell array
            #pragma unroll 
            for (int ang = 0; ang < THR_ANGLES; ang++)
              psii[ang] = angle_read(ghostx_in_ptr, ghostx_in_offsets,
                                     ghost_point, ang);
          } 
          // Else nothing: psii already contains next flux
        } else {
          // reading from x+1
          Point<3> ghost_point = local_point;
          ghost_point.x[0] += 1;
          // Local coordinates here
          if (x == 0) {
            // Ghost cell array
            #pragma unroll
            for (int ang = 0; ang < THR_ANGLES; ang++)
              psii[ang] = angle_read(ghostx_in_ptr, ghostx_in_offsets,
                                     ghost_point, ang);
          }
          // Else nothing: psii already contains next flux
        }
        #pragma unroll
        for (int ang = 0; ang < THR_ANGLES; ang++)
          pc[ang] += psii[ang] * device_mu[ang*blockDim.x + threadIdx.x] * hi;
        // Y ghost cells
        if (stride_y_positive) {
          // reading from y-1
          Point<3> ghost_point = local_point;
          ghost_point.x[1] -= 1;
          if (y == 0) {
            // Ghost cell array
            #pragma unroll
            for (int ang = 0; ang < THR_ANGLES; ang++)
              psij[ang] = angle_read(ghosty_in_ptr, ghosty_in_offsets,
                                     ghost_point, ang);
          } else {
            // Local array
            #pragma unroll
            for (int ang = 0; ang < THR_ANGLES; ang++)
              psij[ang] = yflux_pencils[cta_chunk][x][ang*blockDim.x + threadIdx.x];
          }
        } else {
          // reading from y+1
          Point<3> ghost_point = local_point;
          ghost_point.x[1] += 1;
          // Local coordinates here
          if (y == 0) {
            // Ghost cell array
            #pragma unroll
            for (int ang = 0; ang < THR_ANGLES; ang++)
              psij[ang] = angle_read(ghosty_in_ptr, ghosty_in_offsets,
                                     ghost_point, ang);
          } else {
            // Local array
            #pragma unroll
            for (int ang = 0; ang < THR_ANGLES; ang++)
              psij[ang] = yflux_pencils[cta_chunk][x][ang*blockDim.x + threadIdx.x];
          }
        }
        #pragma unroll
        for (int ang = 0; ang < THR_ANGLES; ang++)
          pc[ang] += psij[ang] * device_eta[ang * blockDim.x + threadIdx.x] * hj;
        // Z ghost cells
        if (stride_z_positive) {
          // reading from z-1
          Point<3> ghost_point = local_point;
          ghost_point.x[2] -= 1;
          if (z == 0) {
            // Ghost cell array
            #pragma unroll
            for (int ang = 0; ang < THR_ANGLES; ang++)
              psik[ang] = angle_read(ghostz_in_ptr, ghostz_in_offsets,
                                     ghost_point, ang);
          } else {
            // Local array
            #pragma unroll
            for (int ang = 0; ang < THR_ANGLES; ang++)
              psik[ang] = zflux_planes[cta_chunk][y][x][ang*blockDim.x + threadIdx.x];
          }
        } else {
          // reading from z+1
          Point<3> ghost_point = local_point;
          ghost_point.x[2] += 1;
          // Local coordinates here
          if (z == 0) {
            // Ghost cell array
            #pragma unroll
            for (int ang = 0; ang < THR_ANGLES; ang++)
              psik[ang] = angle_read(ghostz_in_ptr, ghostz_in_offsets,
                                     ghost_point, ang);
          } else {
            // Local array
            #pragma unroll
            for (int ang = 0; ang < THR_ANGLES; ang++)
              psik[ang] = zflux_planes[cta_chunk][y][x][ang*blockDim.x + threadIdx.x];
          }
        }
        #pragma unroll
        for (int ang = 0; ang < THR_ANGLES; ang++)
          pc[ang] += psik[ang] * device_xi[ang * blockDim.x + threadIdx.x] * hk;

        #pragma unroll
        for (int ang = 0; ang < THR_ANGLES; ang++) {
          double dinv = angle_read(dinv_ptr, dinv_offsets, local_point, ang);
          pc[ang] *= dinv;
        }

        // DO THE FIXUP
        #pragma unroll
        for (int ang = 0; ang < THR_ANGLES; ang++)
          hv_x[ang] = 1.0;
        #pragma unroll
        for (int ang = 0; ang < THR_ANGLES; ang++)
          hv_y[ang] = 1.0;
        #pragma unroll
        for (int ang = 0; ang < THR_ANGLES; ang++)
          hv_z[ang] = 1.0;

        const double t_xs = *(t_xs_ptr + t_xs_offsets * local_point);
        int old_negative_fluxes = 0;
        while (true) {
          unsigned negative_fluxes = 0;
          // Figure out how many negative fluxes we have
          #pragma unroll
          for (int ang = 0; ang < THR_ANGLES; ang++) {
            fx_hv_x[ang] = 2.0 * pc[ang] - psii[ang];
            if (fx_hv_x[ang] < 0.0) {
              hv_x[ang] = 0.0;
              negative_fluxes++;
            }
          }
          #pragma unroll
          for (int ang = 0; ang < THR_ANGLES; ang++) {
            fx_hv_y[ang] = 2.0 * pc[ang] - psij[ang];
            if (fx_hv_y[ang] < 0.0) {
              hv_y[ang] = 0.0;
              negative_fluxes++;
            }
          }
          #pragma unroll
          for (int ang = 0; ang < THR_ANGLES; ang++) {
            fx_hv_z[ang] = 2.0 * pc[ang] - psik[ang];
            if (fx_hv_z[ang] < 0.0) {
              hv_z[ang] = 0.0;
              negative_fluxes++;
            }
          }
          // CTA-wide reduction
          #pragma unroll
          for (int i = 16; i >= 1; i /= 2)
            negative_fluxes += __shfl_xor(negative_fluxes, i, 32);
          // Initialize
          if (warpid == 0)
            int_trampoline[laneid] = 0;
          __syncthreads();
          if (laneid == 0)
            int_trampoline[warpid] = negative_fluxes;
          __syncthreads();
          negative_fluxes = int_trampoline[laneid];
          #pragma unroll
          for (int i = 16; i >= 1; i /= 2)
            negative_fluxes += __shfl_xor(negative_fluxes, i, 32);
          // All threads have the same negative flux count now
          if (negative_fluxes == old_negative_fluxes)
            break;
          old_negative_fluxes = negative_fluxes;
          #pragma unroll
          for (int ang = 0; ang < THR_ANGLES; ang++) {
            pc[ang] = psi[ang] + 0.5 * (
              psii[ang] * device_mu[ang*blockDim.x + threadIdx.x] * hi * (1.0 + hv_x[ang]) +
              psij[ang] * device_eta[ang*blockDim.x + threadIdx.x] * hj * (1.0 + hv_y[ang]) +
              psik[ang] * device_xi[ang*blockDim.x + threadIdx.x] * hk * (1.0 + hv_z[ang]) );
            double den = (pc[ang] <= 0.0) ? 0.0 : (t_xs + 
                device_mu[ang*blockDim.x + threadIdx.x] * hi * hv_x[ang] + 
                device_eta[ang*blockDim.x + threadIdx.x] * hj * hv_y[ang] + 
                device_xi[ang*blockDim.x + threadIdx.x] * hk * hv_z[ang]);
            if (den < tolr)
              pc[ang] = 0.0;
            else
              pc[ang] /= den;
          }
        }
        // Fixup done so compute the update values
        #pragma unroll
        for (int ang = 0; ang < THR_ANGLES; ang++)
          psii[ang] = fx_hv_x[ang] * hv_x[ang];
        #pragma unroll
        for (int ang = 0; ang < THR_ANGLES; ang++)
          psij[ang] = fx_hv_y[ang] * hv_y[ang];
        #pragma unroll
        for (int ang = 0; ang < THR_ANGLES; ang++)
          psik[ang] = fx_hv_z[ang] * hv_z[ang];
        // Write out the ghost regions
        // X ghost
        if (x == (x_range - 1)) {
          #pragma unroll
          for (int ang = 0; ang < THR_ANGLES; ang++)
            angle_write(ghostx_out_ptr, ghostx_out_offsets,
                        local_point, ang, psii[ang]);
        }
        // Y ghost
        if (y == (y_range - 1)) {
          #pragma unroll
          for (int ang = 0; ang < THR_ANGLES; ang++)
            angle_write(ghosty_out_ptr, ghosty_out_offsets,
                        local_point, ang, psij[ang]);
        } else {
          // Write to the pencil
          #pragma unroll
          for (int ang = 0; ang < THR_ANGLES; ang++)
            yflux_pencils[cta_chunk][x][ang*blockDim.x + threadIdx.x] = psij[ang];
        }
        // Z ghost
        if (z == (z_range - 1)) {
          #pragma unroll
          for (int ang = 0; ang < THR_ANGLES; ang++)
            angle_write(ghostz_out_ptr, ghostz_out_offsets,
                        local_point, ang, psik[ang]);
        } else {
          #pragma unroll
          for (int ang = 0; ang < THR_ANGLES; ang++)
            zflux_planes[cta_chunk][y][x][ang*blockDim.x + threadIdx.x] = psik[ang];
        }
        // Finally we apply reductions to the flux moments
        double total = 0.0;  
        #pragma unroll
        for (int ang = 0; ang < THR_ANGLES; ang++) {
          psi[ang] = device_w[ang * blockDim.x + threadIdx.x] * pc[ang];
          total += psi[ang];
        }
        // CTA-wide reduction to one warp and then down to one thread
        #pragma unroll
        for (int i = 16; i >= 1; i /= 2) {
          int hi_part = __shfl_xor(__double2hiint(total), i, 32);
          int lo_part = __shfl_xor(__double2loint(total), i, 32);
          total += __hiloint2double(hi_part,lo_part); 
        }
        if (warpid == 0)
          double_trampoline[laneid] = 0.0;
        __syncthreads();
        if (laneid == 0)
          double_trampoline[warpid] = total;
        __syncthreads();
        if (warpid == 0) {
          total = double_trampoline[laneid];
          #pragma unroll
          for (int i = 16; i >= 1; i /= 2) {
            int hi_part = __shfl_xor(__double2hiint(total), i, 32);
            int lo_part = __shfl_xor(__double2loint(total), i, 32);
            total += __hiloint2double(hi_part,lo_part); 
          }
          // Do the reduction
          if (laneid == 0) {
            double *local_flux = flux_ptr + flux_offsets * local_point;
            atomicAdd(local_flux, total);
          }
        }
        if (num_moments > 1) {
          for (int l = 1; l < num_moments; l++) {
            const int offset = l * num_angles + corner * num_angles * num_moments;
            total = 0.0;
            #pragma unroll
            for (int ang = 0; ang < THR_ANGLES; ang++)
              total += device_ec[offset + ang] * psi[ang];
            __syncthreads();
            if (warpid == 0)
              double_trampoline[laneid] = 0.0;
            __syncthreads();
            if (laneid == 0)
              double_trampoline[warpid] = total;
            __syncthreads();
            if (warpid == 0)
              total = double_trampoline[laneid];
            #pragma unroll
            for (int i = 16; i >= 1; i /= 2) {
              int hi_part = __shfl_xor(__double2hiint(total), i, 32);
              int lo_part = __shfl_xor(__double2loint(total), i, 32);
              total += __hiloint2double(hi_part,lo_part); 
            }
            if (laneid == 0) {
              double *local_fluxm = (double*)(fluxm_ptr + fluxm_offsets * local_point);
              local_fluxm += (l-1);
              atomicAdd(local_fluxm, total);
            }
          }
        }
      }
    }
  }
  // Release our CTA chunk back to the pool
  atomicInc(available_chunks+cta_chunk, 1);
}

template<int THR_ANGLES>
__global__
void gpu_time_independent_sweep_without_fixup(const Point<3> origin, 
                                         const MomentQuad *qtot_ptr,
                                               double     *flux_ptr,
                                               MomentQuad *fluxm_ptr,
                                         const double     *dinv_ptr,
                                         const double     *t_xs_ptr,
                                               double     *ghostx_out_ptr,
                                               double     *ghosty_out_ptr,
                                               double     *ghostz_out_ptr,
                                         const double     *qim_ptr,
                                         const double     *ghostx_in_ptr,
                                         const double     *ghosty_in_ptr,
                                         const double     *ghostz_in_ptr,
                                         const ByteOffset qtot_offsets[3],
                                         const ByteOffset flux_offsets[3],
                                         const ByteOffset fluxm_offsets[3],
                                         const ByteOffset dinv_offsets[3],
                                         const ByteOffset t_xs_offsets[3],
                                         const ByteOffset ghostx_out_offsets[3],
                                         const ByteOffset ghosty_out_offsets[3],
                                         const ByteOffset ghostz_out_offsets[3],
                                         const ByteOffset qim_offsets[3],
                                         const ByteOffset ghostx_in_offsets[3],
                                         const ByteOffset ghosty_in_offsets[3],
                                         const ByteOffset ghostz_in_offsets[3],
                                         const int x_range, const int y_range, 
                                         const int z_range, const int corner,
                                         const bool stride_x_positive,
                                         const bool stride_y_positive,
                                         const bool stride_z_positive,
                                         const bool mms_source, 
                                         const int num_moments, 
                                         const double hi, const double hj,
                                         const double hk) 
{
  __shared__ int int_trampoline;
  __shared__ double double_trampoline[32];

  double psi[THR_ANGLES];
  double pc[THR_ANGLES];
  double psii[THR_ANGLES];
  double psij[THR_ANGLES];
  double psik[THR_ANGLES];

  const int num_angles = THR_ANGLES * blockDim.x;
  const int corner_offset = corner * num_angles * num_moments; 

  unsigned laneid;
  asm volatile("mov.u32 %0, %laneid;" : "=r"(laneid) : );
  unsigned warpid;
  asm volatile("mov.u32 %0, %warpid;" : "=r"(warpid) : );

  // Get a chunk for this CTA
  if ((warpid == 0) && (laneid == 0)) {
    // Start at our SM ID to avoid contention
    int smid;
    asm volatile("mov.u32 %0, %smid;" : "=r"(smid) : );
    int chunk = -1;
    while (chunk < 0) {
      #pragma unroll
      for (int i = 0; i < MAX_CTA; i++) {
        int offset = (smid + i) % MAX_CTA;
        if (atomicDec(available_chunks+offset, 0) == 1) {
          chunk = offset;
          break;
        }
      }
    }
    int_trampoline = chunk;
  }
  __syncthreads();
  const int cta_chunk = int_trampoline;
  __syncthreads();

  for (int z = 0; z < z_range; z++) {
    for (int y = 0; y < y_range; y++) {
      for (int x = 0; x < x_range; x++) {
        // Figure out the local point that we are working on    
        Point<3> local_point = origin;
        if (stride_x_positive)
          local_point.x[0] += x;
        else
          local_point.x[0] -= x;
        if (stride_y_positive)
          local_point.x[1] += y;
        else
          local_point.x[1] -= y;
        if (stride_z_positive)
          local_point.x[2] += z;
        else
          local_point.x[2] -= z;

        // Compute the angular source
        MomentQuad quad = *(qtot_ptr + qtot_offsets * local_point);
        #pragma unroll
        for (int ang = 0; ang < THR_ANGLES; ang++)
          psi[ang] = quad[0];
        if (num_moments > 1) {
          for (int l = 1; l < num_moments; l++) {
            const int moment_offset = corner_offset + l * num_angles;
            #pragma unroll
            for (int ang = 0; ang < THR_ANGLES; ang++) {
              psi[ang] += device_ec[moment_offset+ang*blockDim.x+threadIdx.x] * quad[l];
            }
          }
        }

        // If we're doing MMS
        if (mms_source) {
          #pragma unroll
          for (int ang = 0; ang < THR_ANGLES; ang++)
            psi[ang] += angle_read(qim_ptr, qim_offsets, local_point, ang);
        }

        // Compute the initial solution
        #pragma unroll
        for (int ang = 0; ang < THR_ANGLES; ang++)
          pc[ang] = psi[ang];
        // X ghost cells
        if (stride_x_positive) {
          // reading from x-1 
          Point<3> ghost_point = local_point;
          ghost_point.x[0] -= 1;
          if (x == 0) {
            // Ghost cell array
            #pragma unroll 
            for (int ang = 0; ang < THR_ANGLES; ang++)
              psii[ang] = angle_read(ghostx_in_ptr, ghostx_in_offsets,
                                     ghost_point, ang);
          } 
          // Else nothing: psii already contains next flux
        } else {
          // reading from x+1
          Point<3> ghost_point = local_point;
          ghost_point.x[0] += 1;
          // Local coordinates here
          if (x == 0) {
            // Ghost cell array
            #pragma unroll
            for (int ang = 0; ang < THR_ANGLES; ang++)
              psii[ang] = angle_read(ghostx_in_ptr, ghostx_in_offsets,
                                     ghost_point, ang);
          }
          // Else nothing: psii already contains next flux
        }
        #pragma unroll
        for (int ang = 0; ang < THR_ANGLES; ang++)
          pc[ang] += psii[ang] * device_mu[ang*blockDim.x + threadIdx.x] * hi;
        // Y ghost cells
        if (stride_y_positive) {
          // reading from y-1
          Point<3> ghost_point = local_point;
          ghost_point.x[1] -= 1;
          if (y == 0) {
            // Ghost cell array
            #pragma unroll
            for (int ang = 0; ang < THR_ANGLES; ang++)
              psij[ang] = angle_read(ghosty_in_ptr, ghosty_in_offsets,
                                     ghost_point, ang);
          } else {
            // Local array
            #pragma unroll
            for (int ang = 0; ang < THR_ANGLES; ang++)
              psij[ang] = yflux_pencils[cta_chunk][x][ang*blockDim.x + threadIdx.x];
          }
        } else {
          // reading from y+1
          Point<3> ghost_point = local_point;
          ghost_point.x[1] += 1;
          // Local coordinates here
          if (y == 0) {
            // Ghost cell array
            #pragma unroll
            for (int ang = 0; ang < THR_ANGLES; ang++)
              psij[ang] = angle_read(ghosty_in_ptr, ghosty_in_offsets,
                                     ghost_point, ang);
          } else {
            // Local array
            #pragma unroll
            for (int ang = 0; ang < THR_ANGLES; ang++)
              psij[ang] = yflux_pencils[cta_chunk][x][ang*blockDim.x + threadIdx.x];
          }
        }
        #pragma unroll
        for (int ang = 0; ang < THR_ANGLES; ang++)
          pc[ang] += psij[ang] * device_eta[ang * blockDim.x + threadIdx.x] * hj;
        // Z ghost cells
        if (stride_z_positive) {
          // reading from z-1
          Point<3> ghost_point = local_point;
          ghost_point.x[2] -= 1;
          if (z == 0) {
            // Ghost cell array
            #pragma unroll
            for (int ang = 0; ang < THR_ANGLES; ang++)
              psik[ang] = angle_read(ghostz_in_ptr, ghostz_in_offsets,
                                     ghost_point, ang);
          } else {
            // Local array
            #pragma unroll
            for (int ang = 0; ang < THR_ANGLES; ang++)
              psik[ang] = zflux_planes[cta_chunk][y][x][ang*blockDim.x + threadIdx.x];
          }
        } else {
          // reading from z+1
          Point<3> ghost_point = local_point;
          ghost_point.x[2] += 1;
          // Local coordinates here
          if (z == 0) {
            // Ghost cell array
            #pragma unroll
            for (int ang = 0; ang < THR_ANGLES; ang++)
              psik[ang] = *((ghostz_in_ptr + ghostz_in_offsets * ghost_point) + 
                            ang*blockDim.x + threadIdx.x);
          } else {
            // Local array
            #pragma unroll
            for (int ang = 0; ang < THR_ANGLES; ang++)
              psik[ang] = zflux_planes[cta_chunk][y][x][ang*blockDim.x + threadIdx.x];
          }
        }
        #pragma unroll
        for (int ang = 0; ang < THR_ANGLES; ang++)
          pc[ang] += psik[ang] * device_xi[ang * blockDim.x + threadIdx.x] * hk;

        #pragma unroll
        for (int ang = 0; ang < THR_ANGLES; ang++) {
          double dinv = angle_read(dinv_ptr, dinv_offsets, local_point, ang);
          pc[ang] *= dinv;
        }

        // NO FIXUP
        #pragma unroll
        for (int ang = 0; ang < THR_ANGLES; ang++)
          psii[ang] = 2.0 * pc[ang] - psii[ang];
        #pragma unroll
        for (int ang = 0; ang < THR_ANGLES; ang++)
          psij[ang] = 2.0 * pc[ang] - psij[ang];
        #pragma unroll
        for (int ang = 0; ang < THR_ANGLES; ang++)
          psik[ang] = 2.0 * pc[ang] - psik[ang];

        // Write out the ghost regions
        // X ghost
        if (x == (x_range - 1)) {
          #pragma unroll
          for (int ang = 0; ang < THR_ANGLES; ang++)
            angle_write(ghostx_out_ptr, ghostx_out_offsets,
                        local_point, ang, psii[ang]);
        }
        // Y ghost
        if (y == (y_range - 1)) {
          #pragma unroll
          for (int ang = 0; ang < THR_ANGLES; ang++)
            angle_write(ghosty_out_ptr, ghosty_out_offsets,
                        local_point, ang, psij[ang]);
        } else {
          // Write to the pencil
          #pragma unroll
          for (int ang = 0; ang < THR_ANGLES; ang++)
            yflux_pencils[cta_chunk][x][ang*blockDim.x + threadIdx.x] = psij[ang];
        }
        // Z ghost
        if (z == (z_range - 1)) {
          #pragma unroll
          for (int ang = 0; ang < THR_ANGLES; ang++)
            angle_write(ghostz_out_ptr, ghostz_out_offsets,
                        local_point, ang, psik[ang]);
        } else {
          #pragma unroll
          for (int ang = 0; ang < THR_ANGLES; ang++)
            zflux_planes[cta_chunk][y][x][ang*blockDim.x + threadIdx.x] = psik[ang];
        }
        // Finally we apply reductions to the flux moments
        double total = 0.0;  
        #pragma unroll
        for (int ang = 0; ang < THR_ANGLES; ang++) {
          psi[ang] = device_w[ang * blockDim.x + threadIdx.x] * pc[ang];
          total += psi[ang];
        }
        // CTA-wide reduction to one warp and then down to one thread
        #pragma unroll
        for (int i = 16; i >= 1; i /= 2) {
          int hi_part = __shfl_xor(__double2hiint(total), i, 32);
          int lo_part = __shfl_xor(__double2loint(total), i, 32);
          total += __hiloint2double(hi_part,lo_part); 
        }
        if (warpid == 0)
          double_trampoline[laneid] = 0.0;
        __syncthreads();
        if (laneid == 0)
          double_trampoline[warpid] = total;
        __syncthreads();
        if (warpid == 0) {
          total = double_trampoline[laneid];
          #pragma unroll
          for (int i = 16; i >= 1; i /= 2) {
            int hi_part = __shfl_xor(__double2hiint(total), i, 32);
            int lo_part = __shfl_xor(__double2loint(total), i, 32);
            total += __hiloint2double(hi_part,lo_part); 
          }
          // Do the reduction
          if (laneid == 0) {
            double *local_flux = flux_ptr + flux_offsets * local_point;
            atomicAdd(local_flux, total);
          }
        }
        if (num_moments > 1) {
          for (int l = 1; l < num_moments; l++) {
            const int offset = l * num_angles + corner * num_angles * num_moments;
            total = 0.0;
            #pragma unroll
            for (int ang = 0; ang < THR_ANGLES; ang++)
              total += device_ec[offset + ang] * psi[ang];
            __syncthreads();
            if (warpid == 0)
              double_trampoline[laneid] = 0.0;
            __syncthreads();
            if (laneid == 0)
              double_trampoline[warpid] = total;
            __syncthreads();
            if (warpid == 0)
              total = double_trampoline[laneid];
            #pragma unroll
            for (int i = 16; i >= 1; i /= 2) {
              int hi_part = __shfl_xor(__double2hiint(total), i, 32);
              int lo_part = __shfl_xor(__double2loint(total), i, 32);
              total += __hiloint2double(hi_part,lo_part); 
            }
            if (laneid == 0) {
              double *local_fluxm = (double*)(fluxm_ptr + fluxm_offsets * local_point);
              local_fluxm += (l-1);
              atomicAdd(local_fluxm, total);
            }
          }
        }
      }
    }
  }
  // Release our CTA chunk back to the pool
  atomicInc(available_chunks+cta_chunk, 1);
}

__host__
void run_gpu_sweep(const Point<3> origin, 
               const MomentQuad *qtot_ptr,
                     double     *flux_ptr,
                     MomentQuad *fluxm_ptr,
               const double     *dinv_ptr,
               const double     *time_flux_in_ptr,
                     double     *time_flux_out_ptr,
               const double     *t_xs_ptr,
                     double     *ghostx_out_ptr,
                     double     *ghosty_out_ptr,
                     double     *ghostz_out_ptr,
               const double     *qim_ptr,
               const double     *ghostx_in_ptr,
               const double     *ghosty_in_ptr,
               const double     *ghostz_in_ptr,
               const ByteOffset qtot_offsets[3],
               const ByteOffset flux_offsets[3],
               const ByteOffset fluxm_offsets[3],
               const ByteOffset dinv_offsets[3],
               const ByteOffset time_flux_in_offsets[3],
               const ByteOffset time_flux_out_offsets[3],
               const ByteOffset t_xs_offsets[3],
               const ByteOffset ghostx_out_offsets[3],
               const ByteOffset ghosty_out_offsets[3],
               const ByteOffset ghostz_out_offsets[3],
               const ByteOffset qim_offsets[3],
               const ByteOffset ghostx_in_offsets[3],
               const ByteOffset ghosty_in_offsets[3],
               const ByteOffset ghostz_in_offsets[3],
               const int x_range, const int y_range, 
               const int z_range, const int corner,
               const bool stride_x_positive,
               const bool stride_y_positive,
               const bool stride_z_positive,
               const bool mms_source, 
               const int num_moments, 
               const double hi, const double hj,
               const double hk, const double vdelt,
               const int num_angles, const bool fixup)
{
  // Figure out how many angles per thread we need
  const int max_threads_per_cta = 1024;
  const int angles_per_thread = 
    (num_angles + max_threads_per_cta - 1) / max_threads_per_cta;
  // Have to be evenly divisible for now
  assert((num_angles % angles_per_thread) == 0);
  const int threads_per_cta = num_angles / angles_per_thread;
  dim3 block(threads_per_cta, 1, 1);
  // Teehee screw SKED!
  dim3 grid(1,1,1);
  if (fixup) {
    // Need fixup
    if (vdelt != 0.0) {
      // Time dependent
      switch (angles_per_thread)
      {
        case 1:
          {
            gpu_time_dependent_sweep_with_fixup<1><<<grid,block>>>(origin,
                qtot_ptr, flux_ptr, fluxm_ptr, dinv_ptr, time_flux_in_ptr,
                time_flux_out_ptr, t_xs_ptr, ghostx_out_ptr, ghosty_out_ptr,
                ghostz_out_ptr, qim_ptr, ghostx_in_ptr, ghosty_in_ptr,
                ghostz_in_ptr, qtot_offsets, flux_offsets, fluxm_offsets,
                dinv_offsets, time_flux_in_offsets, time_flux_out_offsets,
                t_xs_offsets, ghostx_out_offsets, ghosty_out_offsets,
                ghostz_out_offsets, qim_offsets, ghostx_in_offsets,
                ghosty_in_offsets, ghostz_in_offsets, x_range, y_range,
                z_range, corner, stride_x_positive, stride_y_positive,
                stride_z_positive, mms_source, num_moments, hi, hj, hk, vdelt);
            break;
          }
        case 2:
          {
            gpu_time_dependent_sweep_with_fixup<2><<<grid,block>>>(origin,
                qtot_ptr, flux_ptr, fluxm_ptr, dinv_ptr, time_flux_in_ptr,
                time_flux_out_ptr, t_xs_ptr, ghostx_out_ptr, ghosty_out_ptr,
                ghostz_out_ptr, qim_ptr, ghostx_in_ptr, ghosty_in_ptr,
                ghostz_in_ptr, qtot_offsets, flux_offsets, fluxm_offsets,
                dinv_offsets, time_flux_in_offsets, time_flux_out_offsets,
                t_xs_offsets, ghostx_out_offsets, ghosty_out_offsets,
                ghostz_out_offsets, qim_offsets, ghostx_in_offsets,
                ghosty_in_offsets, ghostz_in_offsets, x_range, y_range,
                z_range, corner, stride_x_positive, stride_y_positive,
                stride_z_positive, mms_source, num_moments, hi, hj, hk, vdelt);
            break;
          }
        default:
          printf("WOW that is a lot of angles! Add more cases!\n");
          assert(false);
      }
    } else {
      // Time independent
      switch (angles_per_thread)
      {
        case 1:
          {
            gpu_time_independent_sweep_with_fixup<1><<<grid,block>>>(origin,
                qtot_ptr, flux_ptr, fluxm_ptr, dinv_ptr, t_xs_ptr, 
                ghostx_out_ptr, ghosty_out_ptr, ghostz_out_ptr, qim_ptr,
                ghostx_in_ptr, ghosty_in_ptr, ghostz_in_ptr, qtot_offsets,
                flux_offsets, fluxm_offsets, dinv_offsets, t_xs_offsets,
                ghostx_out_offsets, ghosty_out_offsets, ghostz_out_offsets,
                qim_offsets, ghostx_in_offsets, ghosty_in_offsets, 
                ghostz_in_offsets, x_range, y_range, z_range, corner, 
                stride_x_positive, stride_y_positive, stride_z_positive,
                mms_source, num_moments, hi, hj, hk);
            break;
          }
        case 2:
          {
            gpu_time_independent_sweep_with_fixup<2><<<grid,block>>>(origin,
                qtot_ptr, flux_ptr, fluxm_ptr, dinv_ptr, t_xs_ptr, 
                ghostx_out_ptr, ghosty_out_ptr, ghostz_out_ptr, qim_ptr,
                ghostx_in_ptr, ghosty_in_ptr, ghostz_in_ptr, qtot_offsets,
                flux_offsets, fluxm_offsets, dinv_offsets, t_xs_offsets,
                ghostx_out_offsets, ghosty_out_offsets, ghostz_out_offsets,
                qim_offsets, ghostx_in_offsets, ghosty_in_offsets, 
                ghostz_in_offsets, x_range, y_range, z_range, corner, 
                stride_x_positive, stride_y_positive, stride_z_positive,
                mms_source, num_moments, hi, hj, hk);
            break;
          }
        default:
          printf("WOW that is a lot of angles! Add more cases!\n");
          assert(false);
      }
    }
  } else {
    // No fixup
    if (vdelt != 0.0) {
      // Time dependent
      switch (angles_per_thread)
      {
        case 1:
          {
            gpu_time_dependent_sweep_without_fixup<1><<<grid,block>>>(origin,
                qtot_ptr, flux_ptr, fluxm_ptr, dinv_ptr, time_flux_in_ptr,
                time_flux_out_ptr, ghostx_out_ptr, ghosty_out_ptr,
                ghostz_out_ptr, qim_ptr, ghostx_in_ptr, ghosty_in_ptr,
                ghostz_in_ptr, qtot_offsets, flux_offsets, fluxm_offsets,
                dinv_offsets, time_flux_in_offsets, time_flux_out_offsets,
                ghostx_out_offsets, ghosty_out_offsets, ghostz_out_offsets, 
                qim_offsets, ghostx_in_offsets, ghosty_in_offsets, 
                ghostz_in_offsets, x_range, y_range, z_range, corner, 
                stride_x_positive, stride_y_positive, stride_z_positive, 
                mms_source, num_moments, hi, hj, hk, vdelt);
            break;
          }
        case 2:
          {
            gpu_time_dependent_sweep_without_fixup<2><<<grid,block>>>(origin,
                qtot_ptr, flux_ptr, fluxm_ptr, dinv_ptr, time_flux_in_ptr,
                time_flux_out_ptr, ghostx_out_ptr, ghosty_out_ptr,
                ghostz_out_ptr, qim_ptr, ghostx_in_ptr, ghosty_in_ptr,
                ghostz_in_ptr, qtot_offsets, flux_offsets, fluxm_offsets,
                dinv_offsets, time_flux_in_offsets, time_flux_out_offsets,
                ghostx_out_offsets, ghosty_out_offsets, ghostz_out_offsets, 
                qim_offsets, ghostx_in_offsets, ghosty_in_offsets, 
                ghostz_in_offsets, x_range, y_range, z_range, corner, 
                stride_x_positive, stride_y_positive, stride_z_positive, 
                mms_source, num_moments, hi, hj, hk, vdelt);
            break;
          }
        default:
          printf("WOW that is a lot of angles! Add more cases!\n");
          assert(false);
      }
    } else {
      // Time independent
      switch (angles_per_thread)
      {
        case 1:
          {
            gpu_time_independent_sweep_without_fixup<1><<<grid,block>>>(origin,
                qtot_ptr, flux_ptr, fluxm_ptr, dinv_ptr, t_xs_ptr, 
                ghostx_out_ptr, ghosty_out_ptr, ghostz_out_ptr, qim_ptr,
                ghostx_in_ptr, ghosty_in_ptr, ghostz_in_ptr, qtot_offsets,
                flux_offsets, fluxm_offsets, dinv_offsets, t_xs_offsets,
                ghostx_out_offsets, ghosty_out_offsets, ghostz_out_offsets,
                qim_offsets, ghostx_in_offsets, ghosty_in_offsets, 
                ghostz_in_offsets, x_range, y_range, z_range, corner, 
                stride_x_positive, stride_y_positive, stride_z_positive,
                mms_source, num_moments, hi, hj, hk);
            break;
          }
        case 2:
          {
            gpu_time_independent_sweep_without_fixup<2><<<grid,block>>>(origin,
                qtot_ptr, flux_ptr, fluxm_ptr, dinv_ptr, t_xs_ptr, 
                ghostx_out_ptr, ghosty_out_ptr, ghostz_out_ptr, qim_ptr,
                ghostx_in_ptr, ghosty_in_ptr, ghostz_in_ptr, qtot_offsets,
                flux_offsets, fluxm_offsets, dinv_offsets, t_xs_offsets,
                ghostx_out_offsets, ghosty_out_offsets, ghostz_out_offsets,
                qim_offsets, ghostx_in_offsets, ghosty_in_offsets, 
                ghostz_in_offsets, x_range, y_range, z_range, corner, 
                stride_x_positive, stride_y_positive, stride_z_positive,
                mms_source, num_moments, hi, hj, hk);
            break;
          }
        default:
          printf("WOW that is a lot of angles! Add more cases!\n");
          assert(false);
      }
    }
  }
}

