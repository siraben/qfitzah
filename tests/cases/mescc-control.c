#include "mescc-control.h"
#include "mescc-control.h"
int values[3] = {3, 4, 5};
int add(int a, int b)
{
  return a + b;
}
int main(void)
{
  struct pair p;
  int i;
  int total = 0;
  int *v = values;
  for (i = 0; i < 3; i = i + 1)
    total = total + v[i];
  p.x = total;
  p.y = 18;
  if (*(v + 1) != 4)
    return 1;
  return add(p.x, p.y) + EXTRA;
}
