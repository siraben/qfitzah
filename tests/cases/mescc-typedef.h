typedef int (*transform_fn)(int);
int call_transform(transform_fn function, int value);
