#include "mescc-typedef.h"
transform_fn saved;
int plus_two(int value) { return value + 2; }
int main(void)
{
    saved = plus_two;
    return call_transform(saved, 40);
}
