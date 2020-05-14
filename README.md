# malloc and pthread shim for bdwgc and Crystal

On Linux this shims the `malloc` family of functions as well as most of the `pthread_` functions for actual thread handling and redirects them to their equivalents from [bdwgc](https://github.com/ivmai/bdwgc).

On other platforms this does nothing.

## Why would you do this?

Looking at bdwgc's `README.linux`, we can find the following sentence:

> Every file that makes thread calls should define GC_THREADS, and then
   include gc.h.  The latter redefines some of the pthread primitives as
   macros which also provide the collector with information it requires.

On Darwin and Windows bdwgc can and does utilize OS APIs to the necessary tracking, but Linux does not provide these.

But what do you do if a shared library spawns threads? The Crystal compiler does not make any effort to redirect those calls to bdwgc. This can lead bdwgc to clobbering the memory allocated there, since it allocates memory using `brk(2)`/`sbrk(2)` rather than the malloc interface and therefore needs to made aware of memory allocated otherwise. `README.linux` continues with:

> A new alternative to (3a) is to build the collector and compile GC clients
   with -DGC_USE_LD_WRAP, and to link the final program with [...]

Which isn't very practical, especially in the Crystal ecosystem. This shard presents an alternative.

## Usage

Make sure you're using Crystal 0.35 or later. Then:

1. Add the dependency to your `shard.yml`:

   ```yaml
   dependencies:
     malloc_pthread_shim:
       github: jhass/crystal-malloc_pthread_shim
       version: 0.1.0
   ```

2. Run `shards install`.
3. Add `require "malloc_pthread_shim"` to your project.
4. Ensure to link your program against glibc.

   If you're unsure on how to do that, you're most likely already doing it. In doubt, just try to ignore this step.

That's it!

## So, how does it work?

Luckily for us the linker looks up symbols starting in the main binary, so any function we define there wins over the one with the same name in any shared libraries. This allows us to override these functions and redirect them to bdwgc. When bdwgc then continues to call the originals, we use `dlopen(3)` to call the unwrapped functions. However for `malloc` and a few related functions we cannot do this, as `dlopen` itself calls them and ends up at our shim function again, resulting in infinite recursion. Here the dependency on glibc comes into play, it provides alternative symbols for those essential functions that we can use to call the originals.

## Contributing

Currently this only handles glibc on Linux. Darwin and Windows seem to be immune to this issue. If you encounter this issue on any other platform or libc, collecting solutions here is welcome!