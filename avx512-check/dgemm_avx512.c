/*
 * DGEMM AVX512 Benchmark
 *
 * A high-performance matrix multiplication benchmark using OpenBLAS
 * to stress-test AVX512 instructions and measure CPU performance.
 *
 *
 * Compile:
 *   gcc -O3 -march=native dgemm_avx512.c -lopenblas -o dgemm_avx512
 *
 * Usage:
 *   ./dgemm_avx512 [matrix_size] [duration_seconds]
 *
 * Example:
 *   ./dgemm_avx512 4096 60
 */

#include <cblas.h>
#include <stdlib.h>
#include <stdio.h>
#include <time.h>

/**
 * Allocate memory aligned to 64-byte boundary
 * This is optimal for AVX512 vector operations (512 bits = 64 bytes)
 */
static void* alloc64(size_t bytes) {
    size_t align = 64;
    size_t padded = (bytes + align - 1) / align * align;
    return aligned_alloc(align, padded);
}

int main(int argc, char** argv) {
    /* Parse command line arguments */
    int N = (argc > 1) ? atoi(argv[1]) : 4096;
    int seconds = (argc > 2) ? atoi(argv[2]) : 60;

    /* Calculate memory requirements */
    long long elems = (long long)N * (long long)N;
    size_t bytes = (size_t)elems * sizeof(double);

    /* Allocate 64-byte aligned matrices */
    double *A = (double*)alloc64(bytes);
    double *B = (double*)alloc64(bytes);
    double *C = (double*)alloc64(bytes);

    if (!A || !B || !C) {
        fprintf(stderr, "ERROR: Allocation failed (N=%d, bytes=%zu)\n", N, bytes);
        fprintf(stderr, "Try a smaller matrix size or increase system memory.\n");
        return 1;
    }

    /* Initialize matrices
     * A = 1.0, B = 2.0, C = 0.0
     * After C = A * B, we expect C[i] = N * 2.0
     */
    for (long long i = 0; i < elems; i++) {
        A[i] = 1.0;
        B[i] = 2.0;
        C[i] = 0.0;
    }

    printf("========================================\n");
    printf("DGEMM AVX512 Benchmark\n");
    printf("========================================\n");
    printf("Matrix size: %d x %d\n", N, N);
    printf("Memory per matrix: %.2f GB\n", bytes / (1024.0 * 1024.0 * 1024.0));
    printf("Total memory: %.2f GB\n", (3.0 * bytes) / (1024.0 * 1024.0 * 1024.0));
    printf("Duration: %d seconds\n", seconds);
    printf("========================================\n");
    printf("Running benchmark...\n\n");

    /* Benchmark loop */
    time_t start = time(NULL);
    int iters = 0;

    while ((int)(time(NULL) - start) < seconds) {
        /* Perform matrix multiplication: C = A * B
         * Using CBLAS interface to OpenBLAS
         * This should utilize AVX512 instructions on compatible CPUs
         */
        cblas_dgemm(CblasRowMajor, CblasNoTrans, CblasNoTrans,
                    N, N, N, 1.0, A, N, B, N, 0.0, C, N);
        iters++;

        /* Print progress every 10 iterations */
        if (iters % 10 == 0) {
            int elapsed = (int)(time(NULL) - start);
            printf("Iteration %d (elapsed: %ds)\n", iters, elapsed);
        }
    }

    int elapsed = (int)(time(NULL) - start);

    printf("\n========================================\n");
    printf("Benchmark Complete\n");
    printf("========================================\n");
    printf("Total iterations: %d\n", iters);
    printf("Actual duration: %d seconds\n", elapsed);
    printf("Iterations/sec: %.2f\n", (double)iters / elapsed);
    printf("Validation: C[0] = %.2f (expected: %.2f)\n", C[0], (double)N * 2.0);

    /* Verify correctness */
    double expected = (double)N * 2.0;
    double diff = C[0] - expected;
    if (diff < 0) diff = -diff;

    if (diff < 0.01) {
        printf("Status: PASS ✓\n");
    } else {
        printf("Status: FAIL ✗ (result mismatch)\n");
    }
    printf("========================================\n");

    /* Cleanup */
    free(A);
    free(B);
    free(C);

    return 0;
}
