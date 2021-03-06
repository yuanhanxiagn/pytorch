#pragma once

// This file provides two functions to help write GPU elementwise kernels:
//
//   gpu_kernel(TensorIterator iter, <lambda>)
//   gpu_kernel_with_scalars(TensorIterator iter, <lambda>)
//
// The gpu_kernel_with_scalars generates specializations that support a
// single scalar CPU argument, such as from `cuda_tensor + 5`. The CPU scalar
// is lifted to a kernel parameter instead of copying to device memory.
// This should be  used in conjunction with TensorIterator::allow_cpu_scalars_,
// which is the default for TensorIterator::binary_op. Otherwise, all inputs
// and the output must be on the GPU.
//
// For example, to write a reciprocal kernel for GPU float Tensors:
//
//   gpu_kernel(iter, []GPU_LAMBDA(float a) {
//    return 1.0f / a;
//   });
//
// To write a multiplication kernel for GPU float Tensors where one argument
// may be a CPU scalar:
//
//   gpu_kernel_with_scalars(iter, []GPU_LAMBDA(float a, float b) {
//     return a * b;
//   });
//
// See BinaryOpsKernel.cu for the complete implementation
//

#include <type_traits>
#include <tuple>

#include <ATen/ATen.h>
#include <ATen/cuda/CUDAContext.h>
#include <ATen/core/Array.h>
#include <ATen/cuda/detail/OffsetCalculator.cuh>
#include <ATen/detail/FunctionTraits.h>
#include <ATen/native/TensorIterator.h>
#include <ATen/native/cuda/MemoryAccess.cuh>
#include <ATen/native/cuda/CUDA9Workarounds.cuh>
#include <c10/macros/Macros.h>
#include <c10/core/ScalarType.h>
#include <c10/util/TypeCast.h>
#include <c10/util/C++17.h>

// Marks a lambda as executable on both the host and device. The __host__
// attribute is important so that we can access static type information from
// the host, even if the function is typically only executed on the device.
#ifndef GPU_LAMBDA
#define GPU_LAMBDA __host__ __device__
#endif

#ifdef __NVCC__
#define ASSERT_HOST_DEVICE_LAMBDA(type) \
  static_assert(__nv_is_extended_host_device_lambda_closure_type(type), \
                #type " must be a __host__ __device__ lambda")
#else
#define ASSERT_HOST_DEVICE_LAMBDA(type)
#endif

static constexpr int launch_size_1d = 512;
static constexpr int launch_size_nd = 128;
static constexpr int launch_bound2 = 4;


namespace at { namespace native {

// NOTE: @zasdfgbnm is currently working on rewriting the gpu loops.
// Some of the old codes has been moved to namespace legacy, and
// new codes will be put into namespace modern. These two namespaces
// will coexists for a while until the rewrite is done. Once the rewrite
// is done, we will remove the legacy and modern namespace and everything
// will be in at::native directly.
namespace legacy {

template<int nt, int vt, typename func_t>
C10_LAUNCH_BOUNDS_2(nt, launch_bound2)
__global__ void elementwise_kernel(int N, func_t f) {
  int tid = threadIdx.x;
  int nv = nt * vt;
  int idx = nv * blockIdx.x + tid;
  #pragma unroll
  for (int i = 0; i < vt; i++) {
    if (idx < N) {
      f(idx);
      idx += nt;
    }
  }
}

template<int N>
static OffsetCalculator<N> make_offset_calculator(const TensorIterator& iter) {
  AT_ASSERT(N == iter.ntensors());
  std::array<const int64_t*, N> strides;
  for (int i = 0; i < N; i++) {
    strides[i] = iter.strides(i).data();
  }
  return OffsetCalculator<N>(iter.ndim(), iter.shape().data(), strides.data());
}

template<int nt, int vt, typename func_t>
static void launch_kernel(int64_t N, const func_t& f) {
  TORCH_INTERNAL_ASSERT(N >= 0 && N <= std::numeric_limits<int32_t>::max());
  if (N == 0) {
    return;
  }
  dim3 block(nt);
  dim3 grid((N + block.x * vt - 1) / (block.x * vt));
  auto stream = at::cuda::getCurrentCUDAStream();
  elementwise_kernel<nt, vt, func_t><<<grid, block, 0, stream>>>(N, f);
  AT_CUDA_CHECK(cudaGetLastError());
}

template <typename traits, typename func_t, typename index_t, size_t... INDEX>
C10_HOST_DEVICE typename traits::result_type
invoke_impl(const func_t &f, char *const C10_RESTRICT data[], const index_t strides[], int i,
            std::index_sequence<INDEX...>) {
  return f(*(typename traits::template arg<INDEX>::type*)(data[INDEX] + i * strides[INDEX])...);
}

template <typename func_t, typename index_t, typename traits = function_traits<func_t>>
C10_HOST_DEVICE typename traits::result_type
invoke(const func_t &f, char *const C10_RESTRICT data[], const index_t strides[], int i) {
  using Indices = std::make_index_sequence<traits::arity>;
  return invoke_impl<traits>(f, data, strides, i, Indices{});
}

template <typename traits, typename func_t, typename index_t, size_t... I>
C10_HOST_DEVICE typename traits::result_type
invoke_impl(const func_t &f, char *const C10_RESTRICT data[], const index_t strides[], const ScalarType dtypes[], int i,
            std::index_sequence<I...>) {
  return f(c10::fetch_and_cast<typename traits::template arg<I>::type>(dtypes[I], data[I] + i * strides[I])...);
}

template <typename func_t, typename index_t, typename traits = function_traits<func_t>>
C10_HOST_DEVICE typename traits::result_type
invoke(const func_t &f, char *const C10_RESTRICT data[], const index_t strides[], const ScalarType dtypes[], int i) {
  using Indices = std::make_index_sequence<traits::arity>;
  return invoke_impl<traits>(f, data, strides, dtypes, i, Indices{});
}

} // namespace legacy

// See the note for namespace legacy above.
namespace modern {

namespace detail {

// The `pointers` converts std::tuple<T1, T2, ....> to std::tuple<T1*, T2*, ....>

template <typename T>
struct pointers_helper {};

template <typename... types>
struct pointers_helper<std::tuple<types...>> {
  using type = std::tuple<types *...>;
};

template <typename T>
using pointers = typename pointers_helper<T>::type;

// What does the `static_unroll` do?
//
// We want to do something like:
//
//    using args_t = typename traits::ArgsTuple;
//    args_t args;
//    #pragma unroll
//    for (int i = 0; i < traits::arity; i++) {
//      std::get<i>(args) = ....
//    }
//
// but unfortunately the above code does not work because
// the template argument has to be a compile time constant
// so `static_unroll` is created to simulate `#pragma unroll`
// using template metaprogramming.

template<template<int i> typename func, int end, int current=0>
struct static_unroll {
  template<typename... Args>
  static inline C10_HOST_DEVICE void with_args(Args&&... args) {
    func<current>::apply(std::forward<Args>(args)...);
    static_unroll<func, end, current+1>::with_args(args...);
  }
};

template<template<int i> typename func, int end>
struct static_unroll<func, end, end> {
  template<typename... Args>
  static inline C10_HOST_DEVICE void with_args(Args... args) {}
};

template<int i>
struct can_vectorize_up_to_helper {
  template <typename array_t, typename traits>
  static C10_HOST_DEVICE void apply(int &result, array_t pointers, traits _) {
    using arg_t = typename traits::template arg<i>::type;
    // `pointers` hold the data_ptr for tensors [output, input0, input1, ...], so we
    // need a +1 offset to get the input
    result = std::min(result, memory::can_vectorize_up_to<arg_t>(pointers[i + 1]));
  }
};

template<typename func_t, typename array_t>
inline int can_vectorize_up_to(array_t pointers) {
  using traits = function_traits<func_t>;
  using return_t = typename traits::result_type;
  constexpr int arity = traits::arity;
  int result = memory::can_vectorize_up_to<return_t>(pointers[0]);
  // We need to get the type for each argument of `func_t`, this can only
  // be done at compile time.
  static_unroll<can_vectorize_up_to_helper, arity>::with_args(result, pointers, traits());
  return result;
}

}  // namespace detail

template<int i>
struct compute_base_ptrs {
  template <typename arg_ptrs, typename array_t>
  static __device__ void apply(arg_ptrs &args_base, array_t data, int idx) {
    // `data` hold the data_ptr for tensors [output, input0, input1, ...], so we
    // need a +1 offset to get the input
    std::get<i>(args_base) = reinterpret_cast<std::tuple_element_t<i, arg_ptrs>>(data[i + 1]) + idx;
  }
};

template<int i>
struct load_with_policy {
  template <typename args_t, typename policy_t>
  static __device__ void apply(args_t *args, policy_t policy, detail::pointers<args_t> args_base) {
    using arg_t = std::tuple_element_t<i, args_t>;
    auto args_accessor = [&args] __device__ (int index) -> arg_t & { return std::get<i>(args[index]); };
    policy.load(args_accessor, std::get<i>(args_base));
  }
};

template<typename func_t, typename array_t, typename policy_t>
__device__ inline void elementwise_kernel_helper(func_t f, array_t data, policy_t policy) {
  // Assumption:
  // 1. all tensors are contiguous, that is: stride == sizeof(type) for all tensors
  using traits = function_traits<func_t>;
  using return_t = typename traits::result_type;
  using args_t = typename traits::ArgsTuple;
  constexpr int arity = traits::arity;

  // compute base pointers for this block
  int idx = block_work_size * blockIdx.x;
  return_t *result_base = reinterpret_cast<return_t *>(data[0]) + idx;
  detail::pointers<args_t> args_base;
  detail::static_unroll<compute_base_ptrs, arity>::with_args(args_base, data, idx);

  return_t results[thread_work_size];
  cuda9::workaround::enable_default_constructor<args_t> args_[thread_work_size];
  args_t *args = reinterpret_cast<args_t *>(&args_);

  // load
  detail::static_unroll<load_with_policy, arity>::with_args(args, policy, args_base);

  // compute
  #pragma unroll
  for (int i = 0; i < thread_work_size; i++) {
    if (policy.check_inbounds(i)) {
      results[i] = c10::guts::apply(f, args[i]);
    }
  }

  // store
  auto result_accessor = [&] __device__ (int index) -> return_t & { return results[index]; };
  policy.store(result_accessor, result_base);
}

template<int vec_size, typename func_t, typename array_t>
C10_LAUNCH_BOUNDS_1(num_threads)
__global__ void elementwise_kernel(int N, func_t f, array_t data) {
  using return_t = typename function_traits<func_t>::result_type;
  int remaining = N - block_work_size * blockIdx.x;

  if (remaining < block_work_size) {  // if this block handles the reminder, just do a naive unrolled loop
    elementwise_kernel_helper(f, data, typename memory::policies::checked_unroll(remaining));
  } else {  // if this block has a full `block_work_size` data to handle, use vectorized memory access
    elementwise_kernel_helper(f, data, typename memory::policies::template vectorized<vec_size>());
  }
}

// TODO (@zasdfgbnm): this function assume trivial 1d and no dynamic casting
template<typename func_t, typename array_t>
static void launch_kernel(int64_t N, const func_t& f, array_t data) {
  TORCH_INTERNAL_ASSERT(N >= 0 && N <= std::numeric_limits<int32_t>::max());
  if (N == 0) {
    return;
  }
  int64_t grid = (N + block_work_size - 1) / block_work_size;
  auto stream = at::cuda::getCurrentCUDAStream();
  int vec_size = detail::can_vectorize_up_to<func_t>(data);
  switch (vec_size) {
  case 4:
    elementwise_kernel<4, func_t, array_t><<<grid, num_threads, 0, stream>>>(N, f, data);
    break;
  case 2:
    elementwise_kernel<2, func_t, array_t><<<grid, num_threads, 0, stream>>>(N, f, data);
    break;
  case 1:
    elementwise_kernel<1, func_t, array_t><<<grid, num_threads, 0, stream>>>(N, f, data);
    break;
  default:
    TORCH_INTERNAL_ASSERT(false, "Unexpected vectorization size");
  }
  AT_CUDA_CHECK(cudaGetLastError());
}

} // namespace modern


template <typename func_t>
void gpu_kernel_impl(TensorIterator& iter, const func_t& f) {
  using traits = function_traits<func_t>;
  using arg0_t = typename traits::result_type;
  constexpr int ntensors = traits::arity + 1;

  TORCH_INTERNAL_ASSERT(iter.can_use_32bit_indexing());
  TORCH_INTERNAL_ASSERT(iter.ntensors() == traits::arity + 1);

  at::detail::Array<char*, ntensors> data;
  for (int i = 0; i < ntensors; i++) {
    data[i] = (char*)iter.data_ptr(i);
  }

  at::detail::Array<ScalarType, ntensors> dtypes;
  for (int i = 0; i < ntensors; i++) {
    dtypes[i] = iter.tensor(i).scalar_type();
  }

  int64_t numel = iter.numel();
  if (iter.is_trivial_1d()) {
    auto inner_strides = iter.get_inner_strides();
    at::detail::Array<int, ntensors> strides;
    for (int i = 0; i < ntensors; i++) {
      strides[i] = inner_strides[i];
    }

    if (needs_dynamic_casting<func_t>::check(iter)) {
      legacy::launch_kernel<launch_size_1d, 1>(numel, [=]GPU_LAMBDA(int idx) {
        void* out = data[0] + strides[0] * idx;
        arg0_t result = legacy::invoke(f, &data.data[1], &strides.data[1], &dtypes.data[1], idx);
        c10::cast_and_store<arg0_t>(dtypes[0], out, result);
      });
    } else if (iter.has_contiguous_first_dim()) {
      modern::launch_kernel(numel, f, data);
    } else {
      legacy::launch_kernel<launch_size_1d, 1>(numel, [=]GPU_LAMBDA(int idx) {
        arg0_t* out = (arg0_t*)(data[0] + strides[0] * idx);
        *out = legacy::invoke(f, &data.data[1], &strides.data[1], idx);
      });
    }
  } else {
    auto offset_calc = legacy::make_offset_calculator<traits::arity + 1>(iter);
    if (needs_dynamic_casting<func_t>::check(iter)) {
      legacy::launch_kernel<launch_size_nd, launch_bound2>(numel, [=]GPU_LAMBDA(int idx) {
        auto offsets = offset_calc.get(idx);
        void* out = data[0] + offsets[0];
        arg0_t result = legacy::invoke(f, &data.data[1], &offsets.data[1], &dtypes.data[1], 1);
        c10::cast_and_store<arg0_t>(dtypes[0], out, result);
      });
    } else {
      legacy::launch_kernel<launch_size_nd, launch_bound2>(numel, [=]GPU_LAMBDA(int idx) {
        auto offsets = offset_calc.get(idx);
        arg0_t* out = (arg0_t*)(data[0] + offsets[0]);
        *out = legacy::invoke(f, &data.data[1], &offsets.data[1], 1);
      });
    }
  }
}

}} // namespace at::native
