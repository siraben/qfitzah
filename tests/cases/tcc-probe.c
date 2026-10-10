#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdarg.h>

/* Historical MesCC tests target i386; the Blynn route explicitly requests 8. */
#ifndef QFITZAH_POINTER_BYTES
#define QFITZAH_POINTER_BYTES 4
#endif

struct pair { int left; int right; };
static int global = 7;
static int sum(int count, ...)
{
  int total = 0;
  va_list args;
  va_start(args, count);
  while (count--) total += va_arg(args, int);
  va_end(args);
  return total;
}
static int apply(int (*fn)(int, ...)) { return fn(3, 10, 20, 12); }
int main(int argc, char **argv)
{
  int i, total = 0;
  int values[4] = {2, 4, 6, 8};
  struct pair value = {11, 31};
  volatile unsigned long long wide = 0x123456789abcdef0ULL;
  volatile long long negative = -1234567890123LL;
  volatile long long signed_divisor = 1000LL;
  volatile unsigned long long divisor = 0x100000001ULL;
  volatile int shift = 36;
  volatile double a = 1.25, b = 2.5;
  volatile double large = 4294967338.0, fractional = -1234567890.75;
  char buffer[8];
  char inferred[] = "abc";
  char *memory;
  FILE *file;
  if (argc != 2 || global != 7 || sizeof(void *) != QFITZAH_POINTER_BYTES || sizeof(inferred) != 4) return 1;
  for (i = 0; i < 4; ++i) total += *(values + i);
  if (total != 20 || value.left + value.right != 42 || apply(sum) != 42) return 2;
  if ((wide >> 32) != 0x12345678ULL || wide / 16 != 0x123456789abcdefULL) return 3;
  if (negative / signed_divisor != -1234567890LL || negative % signed_divisor != -123LL) return 4;
  if (a + b != 3.75 || b / a != 2.0) return 5;
  if (wide / divisor != 0x12345678ULL || wide % divisor != 0x88888878ULL) return 13;
  if ((wide >> shift) != 0x1234567ULL || (wide << shift) != 0xabcdef0000000000ULL) return 14;
  if ((unsigned long long)large != 4294967338ULL || (long long)fractional != -1234567890LL) return 15;
  if ((double)negative != -1234567890123.0) return 16;
  memory = calloc(8, 1);
  if (!memory || memory[7]) return 6;
  strcpy(memory, "hello");
  memory = realloc(memory, 32);
  if (!memory || strcmp(memory, "hello")) return 7;
  memmove(memory + 1, memory, 6);
  if (strcmp(memory + 1, "hello")) return 8;
  free(memory);
  file = fopen(argv[1], "wb+");
  if (!file) return 9;
  if (fwrite("abc", 1, 3, file) != 3 || fseek(file, 0, SEEK_SET)) return 10;
  memset(buffer, 0, sizeof(buffer));
  if (fread(buffer, 1, 3, file) != 3 || strcmp(buffer, "abc")) return 11;
  if (fclose(file) || remove(argv[1])) return 12;
  puts("tcc C probe passed");
  return 0;
}
