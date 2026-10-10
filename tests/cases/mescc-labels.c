/* Nested expression/statement labels and valid redeclarations must not collide. */
int value;
int value = 42;
int value;
extern int value;
static int other;
static int other = 7;
static int other;
int choose(int flag, int left, int right)
{
    if (flag ? left : right)
        return 1;
    return 0;
}
int nested(int a, int b, int c)
{
    if ((a ? b : c) ? 1 : 0)
        return 1;
    return 0;
}
char *first(void) { return "same string"; }
char *second(void) { return "same string"; }
int main(void)
{
    if (choose(1, 1, 0) != 1 || choose(1, 0, 1) != 0)
        return 1;
    if (choose(0, 1, 0) != 0 || choose(0, 0, 1) != 1)
        return 2;
    if (nested(1, 1, 0) != 1 || nested(0, 1, 0) != 0)
        return 3;
    if (first()[0] != 's' || second()[10] != 'g' || other != 7)
        return 4;
    return value;
}
