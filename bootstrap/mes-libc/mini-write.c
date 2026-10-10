/* Bufferless write adapter for the independently linked Mes libc-mini probe.
   Mes 0.27.1's oputs/eputs reference write, but mini only supplies _write.
   The full tcc profile uses upstream lib/posix/write.c instead. */
#include <mes/lib-mini.h>

ssize_t
write (int fd, void const *buffer, size_t size)
{
  ssize_t result = _write (fd, buffer, size);
  if (result < 0)
    {
      errno = -result;
      return -1;
    }
  errno = 0;
  return result;
}
