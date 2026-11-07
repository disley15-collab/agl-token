// menor_create3.cu — procura, na GPU, o MENOR endereço CREATE3 da CreateX para um salt
// permissionado (salt[0..20) = deployer, salt[20] = 0x00 => mesmo endereço em toda rede).
//
//   guarded = keccak256(pad32(deployer) ++ salt)                       (64 bytes)
//   proxy   = keccak256(0xff ++ CreateX ++ guarded ++ PROXY_HASH)[12:] (85 bytes)
//   addr    = keccak256(0xd6 ++ 0x94 ++ proxy ++ 0x01)[12:]            (23 bytes)
//
// Os 11 bytes livres do salt: salt[21..24) = gid (24 bits), salt[24..32) = semente ^ contador.
// Modo --hook: exige também (addr & 0x3fff) == HOOK_BITS (compilar com -DHOOK_BITS=0x2000 = só BEFORE_INITIALIZE).
// Imprime cada novo recorde (mais zeros à esquerda); o host confere de novo na CPU antes de imprimir.
// Uso: menor_create3 --deployer 0x.. [--hook] [--secs N] [--min-bits B]

#ifndef HOOK_BITS
#define HOOK_BITS 0x2000
#endif
#include <cstdio>
#include <cstdint>
#include <cstring>
#include <cstdlib>
#include <string>
#include <chrono>
#include <random>
#include <cuda_runtime.h>

#define ROTL64(x, y) (((x) << (y)) | ((x) >> (64 - (y))))

__constant__ uint64_t C1[17];  // bloco 1 (guarded) com a parte variável zerada
__constant__ uint64_t C2[17];  // bloco 2 (create2) com o guarded zerado

__host__ __device__ __forceinline__ void keccakf(uint64_t st[25]) {
  constexpr int ROTC[24] = {1,3,6,10,15,21,28,36,45,55,2,14,27,41,56,8,25,43,62,18,39,61,20,44};
  constexpr int PILN[24] = {10,7,11,17,18,3,5,16,8,21,24,4,15,23,19,13,12,2,20,14,22,9,6,1};
  constexpr uint64_t RNDC[24] = {
    0x0000000000000001ULL,0x0000000000008082ULL,0x800000000000808aULL,0x8000000080008000ULL,
    0x000000000000808bULL,0x0000000080000001ULL,0x8000000080008081ULL,0x8000000000008009ULL,
    0x000000000000008aULL,0x0000000000000088ULL,0x0000000080008009ULL,0x000000008000000aULL,
    0x000000008000808bULL,0x800000000000008bULL,0x8000000000008089ULL,0x8000000000008003ULL,
    0x8000000000008002ULL,0x8000000000000080ULL,0x000000000000800aULL,0x800000008000000aULL,
    0x8000000080008081ULL,0x8000000000008080ULL,0x0000000080000001ULL,0x8000000080008008ULL };
  uint64_t t, bc[5];
  #pragma unroll
  for (int r = 0; r < 24; r++) {
    #pragma unroll
    for (int i = 0; i < 5; i++) bc[i] = st[i] ^ st[i+5] ^ st[i+10] ^ st[i+15] ^ st[i+20];
    #pragma unroll
    for (int i = 0; i < 5; i++) { t = bc[(i+4)%5] ^ ROTL64(bc[(i+1)%5], 1); st[i]^=t; st[i+5]^=t; st[i+10]^=t; st[i+15]^=t; st[i+20]^=t; }
    t = st[1];
    #pragma unroll
    for (int i = 0; i < 24; i++) { int j = PILN[i]; bc[0] = st[j]; st[j] = ROTL64(t, ROTC[i]); t = bc[0]; }
    #pragma unroll
    for (int j = 0; j < 25; j += 5) { bc[0]=st[j];bc[1]=st[j+1];bc[2]=st[j+2];bc[3]=st[j+3];bc[4]=st[j+4]; _Pragma("unroll") for (int i = 0; i < 5; i++) st[j+i] ^= (~bc[(i+1)%5]) & bc[(i+2)%5]; }
    st[0] ^= RNDC[r];
  }
}

// Endereço (20 bytes) a partir das lanes variáveis; devolve as 3 lanes de saída do último hash.
__host__ __device__ __forceinline__ void endereco(const uint64_t* c1, const uint64_t* c2,
                                                   uint64_t lane6var, uint64_t lane7, uint64_t out[3]) {
  uint64_t st[25];
  #pragma unroll
  for (int i = 0; i < 17; i++) st[i] = c1[i];
  #pragma unroll
  for (int i = 17; i < 25; i++) st[i] = 0;
  st[6] |= lane6var;
  st[7] = lane7;
  keccakf(st);
  const uint64_t h0 = st[0], h1 = st[1], h2 = st[2], h3 = st[3];  // guarded (LE)

  #pragma unroll
  for (int i = 0; i < 17; i++) st[i] = c2[i];
  #pragma unroll
  for (int i = 17; i < 25; i++) st[i] = 0;
  // guarded começa no byte 21 = lane 2, deslocamento de 5 bytes
  st[2] |= h0 << 40;
  st[3] = (h0 >> 24) | (h1 << 40);
  st[4] = (h1 >> 24) | (h2 << 40);
  st[5] = (h2 >> 24) | (h3 << 40);
  st[6] |= h3 >> 24;
  keccakf(st);
  const uint64_t g1 = st[1], g2 = st[2], g3 = st[3];  // proxy = bytes 12..31

  // 0xd6 0x94 proxy(20) 0x01 | padding 0x01 ... 0x80
  st[0] = 0xd6ULL | (0x94ULL << 8) | ((g1 >> 32) << 16) | (g2 << 48);
  st[1] = (g2 >> 16) | (g3 << 48);
  st[2] = (g3 >> 16) | (0x01ULL << 48) | (0x01ULL << 56);
  #pragma unroll
  for (int i = 3; i < 25; i++) st[i] = 0;
  st[16] = 0x80ULL << 56;
  keccakf(st);
  out[0] = st[1]; out[1] = st[2]; out[2] = st[3];  // endereço = bytes 12..31
}

// bytes do endereço (big-endian) a partir das lanes LE: endereço[k] = hash[12+k]
__host__ __device__ __forceinline__ uint8_t byteEnd(const uint64_t o[3], int k) {
  int b = 12 + k;  // byte do hash
  int lane = b >> 3;  // 1..3
  return (uint8_t)(o[lane - 1] >> (8 * (b & 7)));
}

__host__ __device__ __forceinline__ uint32_t zerosAEsquerda(const uint64_t o[3]) {
  // primeiros 8 bytes do endereço como inteiro big-endian
  uint64_t v = 0;
  for (int k = 0; k < 8; k++) v = (v << 8) | byteEnd(o, k);
#ifdef __CUDA_ARCH__
  return v == 0 ? 64 : __clzll(v);
#else
  return v == 0 ? 64 : __builtin_clzll(v);
#endif
}

__host__ __device__ __forceinline__ bool bitsDeHook(const uint64_t o[3]) {
  uint32_t baixo = ((uint32_t)byteEnd(o, 18) << 8) | byteEnd(o, 19);
  return (baixo & 0x3fff) == HOOK_BITS;
}

struct Achado { uint32_t gid; uint32_t bits; uint64_t lane7; };

__global__ void moer(uint64_t semente, uint64_t base, uint32_t iters, int hook,
                     uint32_t* __restrict__ recorde, uint32_t* __restrict__ n, Achado* __restrict__ buf) {
  const uint32_t gid = blockIdx.x * blockDim.x + threadIdx.x;  // < 2^24
  const uint64_t lane6var = ((uint64_t)gid) << 40;               // salt[21..24) = gid
  uint64_t o[3];
  for (uint32_t it = 0; it < iters; it++) {
    const uint64_t lane7 = semente ^ (base + it);                 // salt[24..32)
    endereco(C1, C2, lane6var, lane7, o);
    const uint32_t z = zerosAEsquerda(o);
    if (z > *recorde && (!hook || bitsDeHook(o))) {
      if (atomicMax(recorde, z) < z) {
        uint32_t i = atomicAdd(n, 1u);
        if (i < 1024) { buf[i].gid = gid; buf[i].bits = z; buf[i].lane7 = lane7; }
      }
    }
  }
}

static std::string aget(int argc, char** argv, const char* k, const char* def) {
  for (int i = 1; i < argc - 1; i++) if (!strcmp(argv[i], k)) return std::string(argv[i + 1]);
  return std::string(def);
}
static bool tem(int argc, char** argv, const char* k) { for (int i = 1; i < argc; i++) if (!strcmp(argv[i], k)) return true; return false; }
static void hexdec(const std::string& in, uint8_t* out, int len) {
  std::string s = in; if (s.rfind("0x", 0) == 0) s = s.substr(2);
  if ((int)s.size() != len * 2) { fprintf(stderr, "hex de %d bytes esperado\n", len); exit(1); }
  for (int i = 0; i < len; i++) out[i] = (uint8_t)strtol(s.substr(i * 2, 2).c_str(), nullptr, 16);
}
static void empacota(const uint8_t* m, uint64_t* lanes) {
  for (int l = 0; l < 17; l++) { uint64_t v = 0; for (int b = 0; b < 8; b++) v |= ((uint64_t)m[l * 8 + b]) << (8 * b); lanes[l] = v; }
}

int main(int argc, char** argv) {
  cudaSetDeviceFlags(cudaDeviceScheduleBlockingSync);
  uint8_t dep[20], cx[20], ph[32];
  hexdec(aget(argc, argv, "--deployer", ""), dep, 20);
  hexdec("ba5Ed099633D3B313e4D5F7bdc1305d3c28ba5Ed", cx, 20);
  hexdec("21c35dbe1b344a2488cf3321d6ce542f8e9f305544ff09e4993a62319a497c1f", ph, 32);
  const int hook = tem(argc, argv, "--hook");
  const double maxSecs = atof(aget(argc, argv, "--secs", "60").c_str());
  uint32_t minBits = (uint32_t)atoi(aget(argc, argv, "--min-bits", "0").c_str());

  // bloco 1: pad32(deployer) ++ salt(deployer ++ 0x00 ++ 11 livres) | 0x01 ... 0x80
  uint8_t m1[136]; memset(m1, 0, 136);
  memcpy(m1 + 12, dep, 20); memcpy(m1 + 32, dep, 20); m1[52] = 0x00;
  m1[64] = 0x01; m1[135] |= 0x80;
  // bloco 2: 0xff ++ CreateX ++ guarded(0) ++ PROXY_HASH | 0x01 ... 0x80
  uint8_t m2[136]; memset(m2, 0, 136);
  m2[0] = 0xff; memcpy(m2 + 1, cx, 20); memcpy(m2 + 53, ph, 32);
  m2[85] = 0x01; m2[135] |= 0x80;
  uint64_t c1[17], c2[17]; empacota(m1, c1); empacota(m2, c2);
  cudaMemcpyToSymbol(C1, c1, sizeof(c1));
  cudaMemcpyToSymbol(C2, c2, sizeof(c2));

  std::random_device rd; const uint64_t semente = ((uint64_t)rd() << 32) ^ rd();
  uint32_t *d_rec, *d_n; Achado* d_buf;
  cudaMalloc(&d_rec, 4); cudaMalloc(&d_n, 4); cudaMalloc(&d_buf, sizeof(Achado) * 1024);
  cudaMemcpy(d_rec, &minBits, 4, cudaMemcpyHostToDevice); cudaMemset(d_n, 0, 4);

  const int threads = 256, blocks = 16384; const uint32_t iters = 64;  // 2^22 threads (gid < 2^24)
  const uint64_t porLancamento = (uint64_t)threads * blocks * iters;
  uint64_t base = 0, total = 0; uint32_t lidos = 0;
  auto t0 = std::chrono::steady_clock::now(), tlog = t0;
  fprintf(stderr, "CREATE3 CreateX · deployer %s · hook=%d · %.0fs\n", aget(argc, argv, "--deployer", "").c_str(), hook, maxSecs);
  for (;;) {
    moer<<<blocks, threads>>>(semente, base, iters, hook, d_rec, d_n, d_buf);
    cudaError_t e = cudaDeviceSynchronize();
    if (e != cudaSuccess) { fprintf(stderr, "erro CUDA: %s\n", cudaGetErrorString(e)); return 2; }
    base += iters; total += porLancamento;
    uint32_t n; cudaMemcpy(&n, d_n, 4, cudaMemcpyDeviceToHost);
    if (n > lidos) {
      Achado a[1024]; uint32_t ate = n < 1024 ? n : 1024;
      cudaMemcpy(a, d_buf, sizeof(Achado) * ate, cudaMemcpyDeviceToHost);
      for (uint32_t i = lidos; i < ate; i++) {
        // confere na CPU antes de imprimir
        uint64_t o[3]; endereco(c1, c2, ((uint64_t)a[i].gid) << 40, a[i].lane7, o);
        if (zerosAEsquerda(o) != a[i].bits || (hook && !bitsDeHook(o))) { fprintf(stderr, "DIVERGENCIA CPU/GPU\n"); return 4; }
        uint8_t salt[32]; memcpy(salt, dep, 20); salt[20] = 0;
        salt[21] = (uint8_t)a[i].gid; salt[22] = (uint8_t)(a[i].gid >> 8); salt[23] = (uint8_t)(a[i].gid >> 16);
        for (int b = 0; b < 8; b++) salt[24 + b] = (uint8_t)(a[i].lane7 >> (8 * b));
        printf("{\"bits\":%u,\"salt\":\"0x", a[i].bits); for (int b = 0; b < 32; b++) printf("%02x", salt[b]);
        printf("\",\"endereco\":\"0x"); for (int k = 0; k < 20; k++) printf("%02x", byteEnd(o, k)); printf("\"}\n");
        fflush(stdout);
      }
      lidos = ate;
    }
    auto agora = std::chrono::steady_clock::now();
    double s = std::chrono::duration<double>(agora - t0).count();
    if (std::chrono::duration<double>(agora - tlog).count() >= 10.0) {
      fprintf(stderr, "  %.1fG tentativas · %.0fM/s\n", total / 1e9, total / s / 1e6); tlog = agora;
    }
    if (s >= maxSecs) { fprintf(stderr, "fim: %.1fG tentativas em %.0fs (%.0fM/s)\n", total / 1e9, s, total / s / 1e6); return 0; }
  }
}
