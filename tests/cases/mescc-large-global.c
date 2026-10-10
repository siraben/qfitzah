/* Same pointer-table size as TCC's hash_ident; verify zero data and endpoints. */
struct entry { int answer; };
struct entry item = {42};
static struct entry *hash_ident[16384];
int main(void)
{
    if (hash_ident[0] != 0 || hash_ident[16383] != 0)
        return 1;
    hash_ident[0] = &item;
    hash_ident[16383] = hash_ident[0];
    return hash_ident[16383]->answer;
}
