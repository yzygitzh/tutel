// Copyright (c) Microsoft Corporation.
// Licensed under the MIT license.

#include <torch/extension.h>
#include <ATen/cuda/CUDAContext.h>
#include <ATen/cuda/CUDAEvent.h>
#include <c10/cuda/CUDACachingAllocator.h>

#if defined(USE_NCCL)
#include <nccl.h>
#endif

#include <vector>
#include <pwd.h>
#include <sys/wait.h>

#include <dlfcn.h>
#include <cuda_runtime.h>
#include <cuda_fp16.h>
#include <cuda.h>
#include <nvrtc.h>

#undef CHECK_EQ
#undef CHECK_NE
#undef CHECK_CPU
#undef CHECK_CUDA
#undef CHECK_CONTIGUOUS

#define CHECK_EQ(x, y) AT_ASSERTM((x) == (y), "CHECK_EQ fails.")
#define CHECK_NE(x, y) AT_ASSERTM((x) != (y), "CHECK_NE fails.")
#define CHECK_CPU(x) AT_ASSERTM(!x.is_cuda(), #x " must be a CPU tensor")
#define CHECK_CUDA(x) AT_ASSERTM(x.is_cuda(), #x " must be a CUDA tensor")
#define CHECK_CONTIGUOUS(x) AT_ASSERTM(x.is_contiguous(), #x " must be contiguous")

static std::string file_read(const char *path) {
  FILE *fp = fopen(path, "rb");
  CHECK_EQ(true, fp != nullptr);
  fseek(fp, 0, SEEK_END);
  size_t code_size = ftell(fp);
  fseek(fp, 0, SEEK_SET);
  std::string code;
  code.resize(code_size);
  CHECK_EQ(code_size, fread((void*)code.data(), 1, code_size, fp));
  fclose(fp);
  return code;
}

static void file_write(const char *path, const std::string &code) {
  FILE *fp = fopen(path, "wb");
  CHECK_EQ(true, fp != nullptr);
  CHECK_EQ(code.size(), fwrite((void*)code.data(), 1, code.size(), fp));
  fclose(fp);
}

static std::string get_cache_path() {
  char *home_path;
  struct stat st = {0};
  if ((home_path = getenv("HOME")) == NULL) {
    home_path = getpwuid(getuid())->pw_dir;
  }
  std::string cache_path(home_path);
  cache_path += "/.cache/";
  if (stat(cache_path.c_str(), &st) == -1) {
    mkdir(cache_path.c_str(), 0755);
  }
  cache_path += "tutel/";
  if (stat(cache_path.c_str(), &st) == -1) {
    mkdir(cache_path.c_str(), 0755);
  }
  cache_path += "kernels/";
  if (stat(cache_path.c_str(), &st) == -1) {
    mkdir(cache_path.c_str(), 0755);
  }

  return cache_path;
}

static std::string nvcc_compile(const char* code, const std::string &arch, int code_id, int dev_id) {
  std::string code_path = get_cache_path() + std::to_string(code_id) + "-" + std::to_string(dev_id) + ".cu";
  file_write(code_path.data(), code);
  pid_t  pid = fork();
  if (pid == 0) {
#if !defined(__HIP_PLATFORM_HCC__)
    CHECK_EQ(-1, execl("/usr/local/cuda/bin/nvcc", "/usr/local/cuda/bin/nvcc", code_path.c_str(), "-o", (code_path + ".fatbin").c_str(), "--fatbin", "-O4", "-gencode", ("arch=compute_" + arch + ",code=sm_" + arch).c_str(), (char *)NULL));
#else
    CHECK_EQ(-1, execl("/opt/rocm/bin/hipcc", "/opt/rocm/bin/hipcc", code_path.c_str(), "-o", (code_path + ".fatbin").c_str(), "--genco", "-O4", "-w" , ("--amdgpu-target=" + arch).c_str(), (char *)NULL));
#endif
    exit(1);
  } else {
    wait(NULL);
  }
  auto image = file_read((code_path + ".fatbin").data());
  remove((code_path + ".fatbin").data());
  return image;
}

static std::string nvrtc_compile(const char* code, const std::string &arch) {
#if !defined(__HIP_PLATFORM_HCC__)
  std::string arch_option = "--gpu-architecture=compute_" + arch;
  std::vector<const char*> param_cstrings = {"--restrict", "--include-path=/usr/local/cuda/include", arch_option.c_str(), "--use_fast_math", "--extra-device-vectorization"};
#else
  std::string arch_option = "--gpu-architecture=" + arch;
  std::vector<const char*> param_cstrings = {arch_option.c_str(), "-O4"};
#endif
  nvrtcProgram prog;

  CHECK_EQ(0, nvrtcCreateProgram(&prog, code, nullptr, 0, nullptr, nullptr));
  nvrtcResult res = nvrtcCompileProgram(prog, param_cstrings.size(), param_cstrings.data());

  size_t log_size;
  CHECK_EQ(0, nvrtcGetProgramLogSize(prog, &log_size));
  std::string log;
  log.resize(log_size);
  CHECK_EQ(0, nvrtcGetProgramLog(prog, &log[0]));
  if (0 != res) {
    LOG(ERROR) << log << " Failed to use NVRTC for JIT compilation in this Pytorch version, try another approach using CUDA compiler.. (To always disable NVRTC, please: export USE_NVRTC=0)";
    return "";
  }

  size_t ptx_size;
  CHECK_EQ(0, nvrtcGetPTXSize(prog, &ptx_size));

  std::string ptx;
  ptx.resize(ptx_size);
  CHECK_EQ(0, nvrtcGetPTX(prog, &ptx[0]));
  CHECK_EQ(0, nvrtcDestroyProgram(&prog));
  return ptx;
}

struct ModuleConfig {
  CUmodule hMod = nullptr;
  CUfunction hFunc = nullptr;

  dim3 blocks, threads;
};

static std::vector<ModuleConfig> gpuModules;

static void invoke(const std::vector<torch::Tensor> &ts, int code_id) {
  auto &gm = gpuModules[code_id];
  std::vector<void*> pargs(ts.size()), ppargs(ts.size());
  for (int i = 0; i < (int)ts.size(); ++i) {
    CHECK_CUDA(ts[i]);
    pargs[i] = (void*)ts[i].data_ptr(), ppargs[i] = &pargs[i];
  }
  CHECK_EQ(0, cuLaunchKernel(gm.hFunc, gm.blocks.x, gm.blocks.y, gm.blocks.z, gm.threads.x, gm.threads.y, gm.threads.z, 0, nullptr, ppargs.data(), nullptr));
}

static void invoke_with_source(const std::vector<torch::Tensor> &ts, int code_id, int flags, const std::string &code) {

#if !defined(__HIP_PLATFORM_HCC__)
#if 0
  static void *libcuda = nullptr;
  static int (*cuModuleLoad)(...) = nullptr;
  static int (*cuModuleGetFunction)(...) = nullptr;
  static int (*cuLaunchKernel)(...) = nullptr;

  if (libcuda == nullptr) {
    (libcuda == nullptr ? (libcuda = dlopen("/usr/local/cuda/compat/lib/libcuda.so.1", RTLD_LAZY | RTLD_GLOBAL)) : 0);
    (libcuda == nullptr ? (libcuda = dlopen("/usr/local/cuda/compat/lib/libcuda.so", RTLD_LAZY | RTLD_GLOBAL)) : 0);
    (libcuda == nullptr ? (libcuda = dlopen("/usr/lib/x86_64-linux-gnu/libcuda.so.1", RTLD_LAZY | RTLD_GLOBAL)) : 0);
    (libcuda == nullptr ? (libcuda = dlopen("/usr/lib/x86_64-linux-gnu/libcuda.so", RTLD_LAZY | RTLD_GLOBAL)) : 0);
    (libcuda == nullptr ? (libcuda = dlopen("/usr/local/lib/x86_64-linux-gnu/libcuda.so.1", RTLD_LAZY | RTLD_GLOBAL)) : 0);
    (libcuda == nullptr ? (libcuda = dlopen("/usr/local/lib/x86_64-linux-gnu/libcuda.so", RTLD_LAZY | RTLD_GLOBAL)) : 0);
    (libcuda == nullptr ? (libcuda = dlopen("/usr/local/cuda/lib64/libcuda.so.1", RTLD_LAZY | RTLD_GLOBAL)) : 0);
    (libcuda == nullptr ? (libcuda = dlopen("/usr/local/cuda/lib64/libcuda.so", RTLD_LAZY | RTLD_GLOBAL)) : 0);
    (libcuda == nullptr ? (libcuda = dlopen("/usr/local/cuda/lib64/stubs/libcuda.so", RTLD_LAZY | RTLD_GLOBAL)) : 0);

    CHECK_NE(nullptr, libcuda);
    CHECK_NE(nullptr, (cuModuleLoad = (decltype(cuModuleLoad))dlsym(libcuda, "cuModuleLoad")));
    CHECK_NE(nullptr, (cuModuleGetFunction = (decltype(cuModuleGetFunction))dlsym(libcuda, "cuModuleGetFunction")));
    CHECK_NE(nullptr, (cuLaunchKernel = (decltype(cuLaunchKernel))dlsym(libcuda, "cuLaunchKernel")));
  }
#endif
#endif

  if (code_id >= (int)gpuModules.size())
    gpuModules.resize(code_id + 1);

  auto &gm = gpuModules[code_id];
  if (gm.hFunc == nullptr) {
    CHECK_CUDA(ts[0]);
    int dev = int(ts[0].device().index());
    CHECK_EQ(0, cudaSetDevice(dev));

#if !defined(__HIP_PLATFORM_HCC__)
    int major, minor;
    CHECK_EQ(0, cudaDeviceGetAttribute(&major, cudaDevAttrComputeCapabilityMajor, dev));
    CHECK_EQ(0, cudaDeviceGetAttribute(&minor, cudaDevAttrComputeCapabilityMinor, dev));
    std::string arch = std::to_string(major) + std::to_string(minor);
#else
    hipDeviceProp_t prop;
    CHECK_EQ(0, hipGetDeviceProperties(&prop, dev));
    std::string arch = prop.gcnArchName;
#endif
    const char *source = code.data(), *pos, *tail;

    int use_nvrtc = flags & 1;
    std::string image;
    if (!use_nvrtc || (image = nvrtc_compile(source, arch)) == "") {
        int dev_ord = dev;
        const char *local_rank = getenv("LOCAL_RANK");
        dev_ord = local_rank ? std::atoi(local_rank) : dev_ord;
        image = nvcc_compile(source, arch, code_id, dev_ord);
    }

    long launch_bound;
    { char tag[] = " __launch_bounds__(";  pos = strstr(source, tag); launch_bound = pos ? std::atol(pos + sizeof(tag) - 1) : 1024L; }

    static CUjit_option options[] = {CU_JIT_OPTIMIZATION_LEVEL, CU_JIT_THREADS_PER_BLOCK};
    static void* values[] = {(void*)4L, (void*)launch_bound};
    CHECK_EQ(0, cuModuleLoadDataEx(&gm.hMod, image.c_str(), sizeof(options) / sizeof(*options), options, values));

    CHECK_EQ(true, nullptr != (pos = strstr(source, " void ")));
    pos += 6; CHECK_EQ(true, nullptr != (tail = strchr(pos, '(')));

    CHECK_EQ(0, cuModuleGetFunction(&gm.hFunc, gm.hMod, std::string(pos, tail - pos).c_str()));
    CHECK_EQ(true, nullptr != gm.hFunc);

    { char tag[] = "// [thread_extent] blockIdx.x = ";  pos = strstr(source, tag); gm.blocks.x = pos ? std::atoi(pos + sizeof(tag) - 1) : 1; }
    { char tag[] = "// [thread_extent] blockIdx.y = ";  pos = strstr(source, tag); gm.blocks.y = pos ? std::atoi(pos + sizeof(tag) - 1) : 1; }
    { char tag[] = "// [thread_extent] blockIdx.z = ";  pos = strstr(source, tag); gm.blocks.z = pos ? std::atoi(pos + sizeof(tag) - 1) : 1; }
    { char tag[] = "// [thread_extent] threadIdx.x = "; pos = strstr(source, tag); gm.threads.x = pos ? std::atoi(pos + sizeof(tag) - 1) : 1; }
    { char tag[] = "// [thread_extent] threadIdx.y = "; pos = strstr(source, tag); gm.threads.y = pos ? std::atoi(pos + sizeof(tag) - 1) : 1; }
    { char tag[] = "// [thread_extent] threadIdx.z = "; pos = strstr(source, tag); gm.threads.z = pos ? std::atoi(pos + sizeof(tag) - 1) : 1; }
  }

  return invoke(ts, code_id);
}

template<typename dtype> static void invoke_cpu(const std::vector<torch::Tensor> &ts, const int &kernel_type, const int &capacity) {
  int samples = ts[1].sizes()[0];
  int hidden = ts[3].sizes()[1];
  if (kernel_type == 0) { //forward
    for (int i = 0; i < samples; ++i) {
      if ((ts[2][i].item<int>() < capacity) && (ts[1][i].item<int>() >= 0)) {
        for (int j = 0; j < hidden; ++j) {
          if (ts[0].sizes().size() == 1) {
            ts[4][ts[1][i].item<int>() * capacity + ts[2][i].item<int>()][j] += ts[0][i].item<dtype>() * ts[3][i][j].item<dtype>();
          } else {
            ts[4][ts[1][i].item<int>() * capacity + ts[2][i].item<int>()][j] += ts[0][i][0].item<dtype>() * ts[3][i][j].item<dtype>();
          }
        }
      }
    }
  } else if (kernel_type == 1) { //backward_data
    for (int i = 0; i < samples; ++i) {
      if ((ts[2][i].item<int>() < capacity) && (ts[1][i].item<int>() >= 0)) {
        for (int j = 0; j < hidden; ++j) {
          if (ts[0].sizes().size() == 1) {
            ts[3][i][j] = ts[0][i].item<dtype>() * ts[4][ts[1][i].item<int>() * capacity + ts[2][i].item<int>()][j];
          } else {
            ts[3][i][j] = ts[0][i][0].item<dtype>() * ts[4][ts[1][i].item<int>() * capacity + ts[2][i].item<int>()][j];
          }
        }
      } else {
        for (int j = 0; j < hidden; ++j) {
          ts[4][i][j] = 0;
        }
      }
    }
  } else { //backward_gate
    for (int block = 0; block < samples; ++block) {
      ts[0][block] = 0;
      dtype grad_gates1_s_rf = 0.0;
      for (int thread = 0; thread < 32; ++thread) {
        if (ts[2][block].item<int>() >= capacity || ts[1][block].item<int>() < 0) {
          if (thread == 0)
            if (ts[0].sizes().size() == 1)
              ts[0][block] = 0;
            else
              ts[0][block][0] = 0;
          return;
        }
        int indice = ts[1][block].item<int>() * capacity + ts[2][block].item<int>();
        for (int i = thread; i < hidden; i += 32)
          grad_gates1_s_rf += ts[4][indice][i].item<dtype>() * ts[3][block][i].item<dtype>();
      }
      ts[0][block] = grad_gates1_s_rf;
    }
  }
}

#if defined(USE_NCCL)

static ncclComm_t g_nccl_comm;
static std::vector<at::cuda::CUDAEvent> g_cuda_events;
static int g_num_split = 0;
static int g_num_slices_per_split = 0;
static int g_world_size = 0;
static int g_world_rank = 0;
static int g_local_size = 0;
static int g_local_rank = 0;

static size_t get_nccl_unique_id_size() {
  return sizeof(ncclUniqueId);
}

static void get_nccl_unique_id(torch::Tensor &nccl_unique_id_tensor) {
  ncclUniqueId nccl_unique_id;

  CHECK_EQ(0, ncclGetUniqueId(&nccl_unique_id));
  CHECK_CPU(nccl_unique_id_tensor);
  CHECK_EQ(nccl_unique_id_tensor.nbytes(), sizeof(ncclUniqueId));
  memcpy((void *)nccl_unique_id_tensor.data_ptr(), &nccl_unique_id, sizeof(ncclUniqueId));
}

static void init_nccl(
    const torch::Tensor &nccl_unique_id_tensor,
    int world_size,
    int world_rank,
    int num_split,
    int num_slices_per_split) {
  ncclUniqueId nccl_unique_id;

  CHECK_CPU(nccl_unique_id_tensor);
  CHECK_EQ(nccl_unique_id_tensor.nbytes(), sizeof(ncclUniqueId));
  memcpy(&nccl_unique_id, (void *)nccl_unique_id_tensor.data_ptr(), sizeof(ncclUniqueId));
  CHECK_EQ(0, ncclGroupStart());
  CHECK_EQ(0, ncclCommInitRank(&g_nccl_comm, world_size, nccl_unique_id, world_rank));
  CHECK_EQ(0, ncclGroupEnd());

  g_num_split = num_split;
  g_cuda_events.resize(num_split);
  g_num_slices_per_split = num_slices_per_split;
  g_world_size = world_size;
  g_world_rank = world_rank;

  char* local_size = std::getenv("LOCAL_SIZE");
  local_size ? g_local_size = std::atoi(local_size) : CHECK_EQ(0, cudaGetDeviceCount(&g_local_size));
  CHECK_EQ(0, ncclCommCuDevice(g_nccl_comm, &g_local_rank));
}

static at::cuda::CUDAStream& get_nccl_stream() {
  static at::cuda::CUDAStream nccl_stream = at::cuda::getStreamFromPool();
  return nccl_stream;
}

static torch::Tensor& current_stream_release(torch::Tensor &tensor, int idx) {
  g_cuda_events[idx].record(at::cuda::getCurrentCUDAStream());
  return tensor;
}

static torch::Tensor& current_stream_acquire(torch::Tensor &tensor, int idx) {
  g_cuda_events[idx].block(at::cuda::getCurrentCUDAStream());
  return tensor;
}

static void nccl_all_to_all_scatter_async(
    const torch::Tensor &input,
    std::vector<torch::Tensor> &output_list,
    bool is_backward) {
  CHECK_CUDA(input);
  CHECK_EQ(g_num_split, output_list.size());
  for (auto& output : output_list) {
    CHECK_CUDA(output);
  }

  CHECK_EQ(0, g_num_slices_per_split % g_world_size);
  size_t length = input.nbytes();
  size_t num_slices = g_num_slices_per_split * g_num_split;
  CHECK_EQ(0, length % num_slices);
  size_t slice_size = length / num_slices;

  // Allocator will add blocking event to nccl stream after nccl kernels
  c10::cuda::CUDACachingAllocator::recordStream(input.storage().data_ptr(), get_nccl_stream());
  for (auto& output : output_list) {
    c10::cuda::CUDACachingAllocator::recordStream(output.storage().data_ptr(), get_nccl_stream());
  }

  // Acquire 0-th event for single input
  g_cuda_events[0].block(get_nccl_stream());

  for (int i = 0; i < g_num_split; i++) {
    // Reverse calculation order in backward for pipelining
    int calc_idx = is_backward ? g_num_split - 1 - i : i;

    CHECK_EQ(0, ncclGroupStart());
    for (int j = 0; j < g_num_slices_per_split; j++) {
      CHECK_EQ(0, ncclSend(
          ((char*)input.data_ptr()) + (j * g_num_split + calc_idx) * slice_size,
          slice_size,
          ncclInt8,
          g_world_size * j / g_num_slices_per_split,
          g_nccl_comm,
          get_nccl_stream().stream()));
      CHECK_EQ(0, ncclRecv(
          ((char*)output_list[calc_idx].data_ptr()) + j * slice_size,
          slice_size,
          ncclInt8,
          g_world_size * j / g_num_slices_per_split,
          g_nccl_comm,
          get_nccl_stream().stream()));
    }
    CHECK_EQ(0, ncclGroupEnd());

    // Release calc_idx-th event
    g_cuda_events[calc_idx].record(get_nccl_stream());
  }
}

static void nccl_all_to_all_gather_async(
    const std::vector<torch::Tensor> &input_list,
    torch::Tensor &output,
    bool is_backward) {
  CHECK_EQ(g_num_split, input_list.size());
  for (auto& input : input_list) {
    CHECK_CUDA(input);
  }
  CHECK_CUDA(output);

  CHECK_EQ(0, g_num_slices_per_split % g_world_size);
  size_t length = output.nbytes();
  size_t num_slices = g_num_slices_per_split * g_num_split;
  CHECK_EQ(0, length % num_slices);
  size_t slice_size = length / num_slices;

  // Allocator will add blocking event to nccl stream after nccl kernels
  for (auto& input : input_list) {
    c10::cuda::CUDACachingAllocator::recordStream(input.storage().data_ptr(), get_nccl_stream());
  }
  c10::cuda::CUDACachingAllocator::recordStream(output.storage().data_ptr(), get_nccl_stream());

  for (int i = 0; i < g_num_split; i++) {
    // Reverse calculation order in backward for pipelining
    int calc_idx = is_backward ? g_num_split - 1 - i : i;

    // Acquire calc_idx-th event
    g_cuda_events[calc_idx].block(get_nccl_stream());

    CHECK_EQ(0, ncclGroupStart());
    for (int j = 0; j < g_num_slices_per_split; j++) {
      CHECK_EQ(0, ncclSend(
          ((char*)input_list[calc_idx].data_ptr()) + j * slice_size,
          slice_size,
          ncclInt8,
          g_world_size * j / g_num_slices_per_split,
          g_nccl_comm,
          get_nccl_stream().stream()));
      CHECK_EQ(0, ncclRecv(
          ((char*)output.data_ptr()) + (j * g_num_split + calc_idx) * slice_size,
          slice_size,
          ncclInt8,
          g_world_size * j / g_num_slices_per_split,
          g_nccl_comm,
          get_nccl_stream().stream()));
    }
    CHECK_EQ(0, ncclGroupEnd());
  }

  // Release 0-th event for single output
  g_cuda_events[0].record(get_nccl_stream());
}

template <typename T>
__global__ void memStrideCopyKernel(
    T *__restrict__ out, const T *__restrict__ in,
    const uint64_t size, const uint64_t height, const uint64_t width) {
    const uint64_t tid = blockIdx.x * blockDim.x + threadIdx.x;
    for (uint64_t i = tid; i < size * height * width; i += gridDim.x * blockDim.x) {
        const uint64_t index = i / size, offset = i % size;
        const uint64_t j = (width * (index % height) + (index / height)) * size + offset;
        out[j] = in[i];
    }
}

static void all_to_all(torch::Tensor &output, torch::Tensor &input, const char *algo) {
  CHECK_CUDA(output);
  CHECK_CUDA(input);
  auto recvbuff = (void*)output.data_ptr();
  auto sendbuff = (void*)input.data_ptr();
  cudaStream_t stream = get_nccl_stream().stream();

  size_t length = input.nbytes();
  CHECK_EQ(0, length % g_world_size);
  size_t slice_size = length / g_world_size;

  int nranks = g_world_size, ngpus = g_local_size;
  CHECK_EQ(0, nranks % ngpus);
  int nnodes = nranks / ngpus;
  if (ngpus == 1 || nnodes == 1) goto linear;

  if (algo && !strcmp(algo, "2D")) {
    int node_rank = g_world_rank / ngpus, local_rank = g_local_rank;
    int gridsize, blocksize;
    CHECK_EQ(0, cudaOccupancyMaxPotentialBlockSize(&gridsize, &blocksize, memStrideCopyKernel<uint4>));
    // phase 0. per-gpu (ngpus) stride copy
    slice_size < sizeof(uint4)
      ? memStrideCopyKernel<char><<<gridsize, blocksize, 0, stream>>>((char*)recvbuff, (char*)sendbuff, slice_size, ngpus, nnodes)
      : memStrideCopyKernel<uint4><<<gridsize, blocksize, 0, stream>>>((uint4*)recvbuff, (uint4*)sendbuff, slice_size/sizeof(uint4), ngpus, nnodes);
    // phase 1. intra-node alltoall
    CHECK_EQ(0, ncclGroupStart());
    for (int g = 0; g < ngpus; g++) {
      CHECK_EQ(0, ncclSend(((char*)recvbuff) + g * nnodes * slice_size, nnodes * slice_size, ncclInt8, g + node_rank * ngpus, comm, stream));
      CHECK_EQ(0, ncclRecv(((char*)sendbuff) + g * nnodes * slice_size, nnodes * slice_size, ncclInt8, g + node_rank * ngpus, comm, stream));
    }
    CHECK_EQ(0, ncclGroupEnd());
    // phase 2. per-gpu (nnodes) stride copy
    slice_size < sizeof(uint4)
      ? memStrideCopyKernel<char><<<gridsize, blocksize, 0, stream>>>((char*)recvbuff, (char*)sendbuff, slice_size, nnodes, ngpus)
      : memStrideCopyKernel<uint4><<<gridsize, blocksize, 0, stream>>>((uint4*)recvbuff, (uint4*)sendbuff, slice_size/sizeof(uint4), nnodes, ngpus);
    // phase 3. inter-node alltoall
    CHECK_EQ(0, ncclGroupStart());
    for (int n = 0; n < nnodes; n++) {
      CHECK_EQ(0, ncclSend(((char*)recvbuff) + n * ngpus * slice_size, ngpus * slice_size, ncclInt8, n * ngpus + local_rank, comm, stream));
      CHECK_EQ(0, ncclRecv(((char*)sendbuff) + n * ngpus * slice_size, ngpus * slice_size, ncclInt8, n * ngpus + local_rank, comm, stream));
    }
    CHECK_EQ(0, ncclGroupEnd());
    CHECK_EQ(0, cudaMemcpyAsync(recvbuff, sendbuff, nranks * slice_size, cudaMemcpyDeviceToDevice, stream));
  } else {
linear:
    CHECK_EQ(0, ncclGroupStart());
    for (int r = 0; r < nranks; r++) {
      CHECK_EQ(0, ncclSend(((char*)sendbuff) + r * slice_size, slice_size, ncclInt8, r, comm, stream));
      CHECK_EQ(0, ncclRecv(((char*)recvbuff) + r * slice_size, slice_size, ncclInt8, r, comm, stream));
    }
    CHECK_EQ(0, ncclGroupEnd());
  }
}

#endif

PYBIND11_MODULE(TORCH_EXTENSION_NAME, m) {
    m.def("invoke",
        &invoke,
        "Generic Invoke (CUDA)"
    );
    m.def("invoke_with_source",
        &invoke_with_source,
        "Generic Invoke with Source (CUDA)"
    );
    m.def("invoke_cpu_fp32",
        &invoke_cpu<float>,
        "Generic Invoke (CPU)"
    );
    m.def("invoke_cpu_fp64",
        &invoke_cpu<double>,
        "Generic Invoke (CPU)"
    );
#if defined(USE_NCCL)
    m.def("get_nccl_unique_id_size",
        &get_nccl_unique_id_size,
        "Get size of ncclUniqueId in bytes"
    );
    m.def("get_nccl_unique_id",
        &get_nccl_unique_id,
        "Get ncclUniqueId for NCCL initialization"
    );
    m.def("init_nccl",
        &init_nccl,
        "NCCL initialization"
    );
    m.def("current_stream_release",
        &current_stream_release,
        "Record CUDA event on current stream to i-th event slot"
    );
    m.def("current_stream_acquire",
        &current_stream_acquire,
        "Let current stream wait CUDA event in i-th event slot"
    );
    m.def("nccl_all_to_all_scatter_async",
        &nccl_all_to_all_scatter_async,
        "NCCL AllToAll (Scatter Async)"
    );
    m.def("nccl_all_to_all_gather_async",
        &nccl_all_to_all_gather_async,
        "NCCL AllToAll (Gather Async)"
    );
    m.def("all_to_all",
        &all_to_all,
        "AllToAll (Async)"
    );
#endif
}