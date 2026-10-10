#define STRINGIFY(x) #x
#define EXPAND_STRING(x) STRINGIFY(x)
#define WORD hello

/* Pinned MesCC miscomputes sizeof for inferred string-initialized arrays.
   Use an explicit bound here; the final TCC probe checks inference too. */
char text[6] = "a\n\"\\b";
int values[] = {10, 20, 12};
char *word = EXPAND_STRING(WORD);
char *quoted = STRINGIFY("a\\b");
int counter;

int main(void)
{
  if (sizeof(text) != 6 || text[0] != 'a' || text[1] != '\n' ||
      text[2] != '"' || text[3] != '\\' || text[4] != 'b' || text[5])
    return 1;
  if (word[0] != 'h' || word[4] != 'o' || word[5])
    return 2;
  if (quoted[0] != '"' || quoted[1] != 'a' || quoted[2] != '\\' ||
      quoted[3] != '\\' || quoted[4] != 'b' || quoted[5] != '"' || quoted[6])
    return 3;
  text[0] = 'z';
  if (sizeof(values) != 12)
    return 5;
  counter = values[0] + values[1] + values[2];
  return text[0] == 'z' ? counter : 4;
}
