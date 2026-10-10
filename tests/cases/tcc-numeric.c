#include <stdio.h>
#include <stdlib.h>

struct division { long long a, b, quotient, remainder; };
static volatile struct division cases[] = {
  {-1234567890123LL, 1000LL, -1234567890LL, -123LL},
  {-1234567890123LL, -1000LL, 1234567890LL, -123LL},
  {1234567890123LL, -1000LL, -1234567890LL, 123LL},
  {-9223372036854775807LL - 1, 3LL, -3074457345618258602LL, -2LL},
  {9223372036854775807LL, 7LL, 1317624576693539401LL, 0LL},
  {-2147483648LL, -1LL, 2147483648LL, 0LL}
};
static int decimal(char *text, unsigned high, unsigned low, int next)
{
  union { double value; unsigned words[2]; } number;
  char *end;
  number.value = strtod(text, &end);
  return number.words[1] == high && number.words[0] == low && *end == next;
}
static int stack_array(int count)
{
  int values[count];
  int i;
  for (i = 0; i < count; ++i) values[i] = 42 + i;
  return values[count - 1] - count + 1;
}
int main(int argc, char **argv)
{
  unsigned i;
  volatile unsigned long long a = 0xffffffffffffffffULL;
  volatile unsigned long long b = 0x100000001ULL;
  for (i = 0; i < sizeof(cases) / sizeof(cases[0]); ++i)
    if (cases[i].a / cases[i].b != cases[i].quotient ||
        cases[i].a % cases[i].b != cases[i].remainder) return 1;
  if (a / b != 0xffffffffULL || a % b != 0) return 2;
  /* IEEE-754 word oracles do not depend on the compiler's decimal reader. */
  if (!decimal("1.25!", 0x3ff40000, 0, '!') ||
      !decimal("3.75", 0x400e0000, 0, 0) ||
      !decimal(" -0.125rest", 0xbfc00000, 0, 'r')) return 3;
  if (!decimal("4294967338.0", 0x41f00000, 0x02a00000, 0) ||
      !decimal("125e-2", 0x3ff40000, 0, 0) ||
      !decimal("1e+", 0x3ff00000, 0, 'e')) return 4;
  if (!decimal("0x1.4p0", 0x3ff40000, 0, 0) ||
      !decimal("-0x1.4p0", 0xbff40000, 0, 0) ||
      !decimal("+.x", 0, 0, '+') ||
      !decimal("0e999999", 0, 0, 0)) return 5;
  if (stack_array(argc + 5) != 42) return 6;
  puts("tcc numeric probe passed");
  return 0;
}
