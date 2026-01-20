#include <cblas.h>
#include <stdlib.h>
#include <stdio.h>
#include <time.h>

static void* alloc64(size_t bytes) {
    size_t align = 64;
    size_t padded = (bytes + align - 1) / align * align;
    return aligned_alloc(align, padded);
}

int main(int argc, char** argv) {
    int N = (argc > 1) ? atoi(argv[1]) : 4096;
    int seconds = (argc > 2) ? atoi(argv[2]) : 60;

    long long elems = (long long)N * (long long)N;
    size_t bytes = (size_t)elems * sizeof(double);

    double *A = (double*)alloc64(bytes);
    double *B = (double*)alloc64(bytes);
    double *C = (double*)alloc64(bytes);

    if (!A || !B || !C) {
        fprintf(stderr, "ERROR: Allocation failed\n");
        return 1;
    }

    for (long long i = 0; i < elems; i++) {
        A[i] = 1.0; B[i] = 2.0; C[i] = 0.0;
    }

    printf("========================================\n");
    printf("DGEMM AVX512 Benchmark\n");
    printf("========================================\n");
    printf("Matrix size: %d x %d\n", N, N);
    printf("Duration:    %d seconds\n", seconds);
    printf("----------------------------------------\n");

    time_t start = time(NULL);
    int iters = 0;

    while ((int)(time(NULL) - start) < seconds) {
        cblas_dgemm(CblasRowMajor, CblasNoTrans, CblasNoTrans,
                    N, N, N, 1.0, A, N, B, N, 0.0, C, N);
        iters++;

        // Update the SAME line instead of printing a new one
        if (iters % 5 == 0) {
            int elapsed = (int)(time(NULL) - start);
            printf("\rRunning: Iteration %d | Elapsed: %ds", iters, elapsed);
            fflush(stdout); // Force the terminal to update immediately
        }
    }

    int elapsed = (int)(time(NULL) - start);
    if (elapsed == 0) elapsed = 1;

    // Calculate GFLOPS: (2 * N^3 * iterations) / (time * 10^9)
    double gflops = (2.0 * N * N * N * iters) / (elapsed * 1e9);

    printf("\n----------------------------------------\n");
    printf("Benchmark Complete\n");
    printf("Total iterations: %d\n", iters);
    printf("Performance:      %.2f GFLOPS\n", gflops);
    printf("Validation:       %s\n", (long)(C[0]) == (long)N * 2 ? "PASS ✓" : "FAIL ✗");
    printf("========================================\n");

    free(A); free(B); free(C);
    return 0;
}
