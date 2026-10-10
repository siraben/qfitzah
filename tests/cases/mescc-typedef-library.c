#include "mescc-typedef.h"
int call_transform(transform_fn function, int value)
{
    if (sizeof(transform_fn) != sizeof(void *))
        return 1;
    return function(value);
}
