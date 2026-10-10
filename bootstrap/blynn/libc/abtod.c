/* GNU Mes abtod replacement for the TCC-built libc.
 * Based on GNU Mes lib/mes/abtod.c:
 * Copyright (C) 2017,2018,2019 Jan (janneke) Nieuwenhuizen.
 * SPDX-License-Identifier: GPL-3.0-or-later
 * Distributed without warranty; see COPYING in this directory for the license.
 *
 * Preserve the bootstrap interface, but do not accumulate through 32-bit long
 * or divide an entire fractional part by just one radix. This is still a
 * small, locale-independent converter, not a correctly-rounded strtod for all
 * inputs. Infinity/NaN spelling and extreme mantissa/exponent cancellation are
 * outside its supported subset. All constants below are integers so the first
 * bootstrap compiler need not parse decimal floating literals to build it.
 */
#include <mes/lib.h>
#include <ctype.h>

static int
qfitzah_abtod_digit (int c, int base)
{
  int digit = -1;
  if (c >= '0' && c <= '9') digit = c - '0';
  else if (c >= 'a' && c <= 'z') digit = c - 'a' + 10;
  else if (c >= 'A' && c <= 'Z') digit = c - 'A' + 10;
  return digit < base ? digit : -1;
}

static double
qfitzah_abtod_exponent (double value, char const **position, int base)
{
  char const *start = *position;
  char const *s = start;
  int negative = 0, exponent = 0;
  int marker = base == 16 ? 'p' : 'e';
  if (*s != marker && *s != marker - 'a' + 'A') return value;
  s++;
  if (*s == '+' || *s == '-') negative = *s++ == '-';
  if (*s < '0' || *s > '9') return value;
  while (*s >= '0' && *s <= '9')
    {
      if (exponent < 4096) exponent = exponent * 10 + *s - '0';
      if (exponent > 4096) exponent = 4096;
      s++;
    }
  *position = s;
  if (value == 0) return value;
  if (base == 16) base = 2;
  while (exponent--)
    value = negative ? value / base : value * base;
  return value;
}

double
abtod (char const **position, int base)
{
  char const *start = *position;
  char const *s = start;
  double value = 0, scale = 1;
  int negative = 0, digits = 0, digit;
  if (!base) base = 10;
  if (base < 2 || base > 36) return value;
  while (isspace (*s)) s++;
  if (*s == '+' || *s == '-') negative = *s++ == '-';
  if ((base == 10 || base == 16) && s[0] == '0' && (s[1] == 'x' || s[1] == 'X'))
    { base = 16; s += 2; }
  while ((digit = qfitzah_abtod_digit (*s, base)) >= 0)
    { value = value * base + digit; s++; digits++; }
  if (*s == '.')
    {
      s++;
      while ((digit = qfitzah_abtod_digit (*s, base)) >= 0)
        { scale = scale / base; value = value + digit * scale; s++; digits++; }
    }
  if (!digits) return value;
  value = qfitzah_abtod_exponent (value, &s, base);
  *position = s;
  return negative ? -value : value;
}
