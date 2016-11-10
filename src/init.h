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

#ifndef __INIT_H__
#define __INIT_H__

#include "snap.h"
#include "legion.h"

using namespace Legion;

class InitMaterial : public SnapTask<InitMaterial> {
public:
  static const Snap::SnapTaskID TASK_ID = Snap::INIT_MATERIAL_TASK_ID;
  static const Snap::SnapReductionID REDOP = Snap::NO_REDUCTION_ID;
public:
  InitMaterial(const Snap &snap, const SnapArray &mat);
public:
  static void preregister_cpu_variants(void);
public:
  static void cpu_implementation(const Task *task,
      const std::vector<PhysicalRegion> &regions, Context ctx, Runtime *runtime);
};

class InitSource : public SnapTask<InitSource> {
public:
  static const Snap::SnapTaskID TASK_ID = Snap::INIT_SOURCE_TASK_ID;
  static const Snap::SnapReductionID REDOP = Snap::NO_REDUCTION_ID;
public:
  InitSource(const Snap &snap, const SnapArray &qi);
public:
  static void preregister_cpu_variants(void);
public:
  static void cpu_implementation(const Task *task,
      const std::vector<PhysicalRegion> &regions, Context ctx, Runtime *runtime);
};

#endif // __INIT_H__

