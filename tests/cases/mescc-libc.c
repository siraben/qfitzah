#include <mes/lib-mini.h>
int same(char const *a, char const *b)
{
  while (*a && *a == *b)
    {
      a = a + 1;
      b = b + 1;
    }
  return *a == *b;
}
int main(int argc, char **argv, char **envp)
{
  int i;
  int found = 0;
  if (argc != 2 || argv[1][0] != 'x' || strlen(argv[1]) != 3)
    return 1;
  if (!envp || environ != envp)
    return 2;
  for (i = 0; envp[i]; i = i + 1)
    if (same(envp[i], "QFITZAH_LIBC_PROBE=yes"))
      found = 1;
  if (!found)
    return 3;
  puts("Mes libc from C source");
  if (write(-1, "", 0) != -1 || errno != 9)
    return 4;
  return 42;
}
