{% skip_file unless flag?(:linux) %}

@[Link(ldflags: "#{__DIR__}/globals.o")]
lib LibGC
  fun initialized = GC_is_init_called : LibC::Int
  fun pthread_sigmask = GC_pthread_sigmask(how : LibC::Int, set : LibC::SigsetT*, oldset : LibC::SigsetT*) : LibC::Int
  fun pthread_exit = GC_pthread_exit(value : Void*)
  fun pthread_cancel = GC_pthread_cancel(thread : LibC::PthreadT) : LibC::Int
  fun dlopen = GC_dlopen(path : LibC::Char*, mode : LibC::Int) : Void*
  fun mark_thread = GC_mark_thread(a : Void*)
  fun malloc_uncollectable = GC_malloc_uncollectable(size : LibC::SizeT) : Void*
  fun set_no_dls = GC_set_no_dls(enabled : LibC::Int)
  fun set_all_interior_pointers = GC_set_all_interior_pointers(enabled : LibC::Int)
  fun set_finalize_on_demand = GC_set_finalize_on_demand(enabled : LibC::Int)
  fun memalign = GC_memalign(align : LibC::SizeT, lb : LibC::SizeT) : Void*
  fun posix_memalign = GC_posix_memalign(ptr : Void**, alignment : LibC::SizeT, size : LibC::SizeT) : LibC::Int
  fun strdup = GC_strdup(str : LibC::Char*) : LibC::Char*
  fun strndup = GC_strndup(str : LibC::Char*, n : LibC::SizeT) : LibC::Char*

  @[ThreadLocal]
  $_inside_gc : LibC::Int
end

lib LibC
  fun real_malloc = __libc_malloc(size : LibC::SizeT) : Void*
  fun real_realloc = __libc_realloc(ptr : Void*, size : LibC::SizeT) : Void*
  fun real_calloc = __libc_calloc(count : LibC::SizeT, size : LibC::SizeT) : Void*
  fun real_free = __libc_free(ptr : Void*)
  fun real_memalign = __libc_memalign(alignment : LibC::SizeT, size : LibC::SizeT) : Void*
end

private def gc_initialized?
  LibGC.initialized != 0
end

private def inside_gc?
  LibGC._inside_gc == 1
end

private def enter_gc
  was_in_gc = LibGC._inside_gc
  LibGC._inside_gc = 1
  ret = yield
  LibGC._inside_gc = was_in_gc
  ret
end

private def open_libc : Void*
  handle = LibGC.dlopen("libc.so.6", LibC::RTLD_LAZY)
  handle = LibGC.dlopen("libc.so", LibC::RTLD_LAZY) unless handle
  handle
end

private def open_libpthread : Void*
  handle = LibGC.dlopen("libpthread.so.0", LibC::RTLD_LAZY)
  handle = LibGC.dlopen("libpthread.so", LibC::RTLD_LAZY) unless handle
  handle
end

private def open_libgc : Void*
  handle = LibGC.dlopen("libgc.so.1", LibC::RTLD_LAZY)
  handle = LibGC.dlopen("libgc.so", LibC::RTLD_LAZY) unless handle
  handle
end

fun gc_init = GC_init
  # We only need to wrap this because we want to be really sure we know we're called from the GC
  handle = open_libgc
  address = LibC.dlsym(handle, "GC_init")
  function = Proc(Void).new(address, Pointer(Void).null)
  enter_gc { function.call }
end

fun malloc(size : LibC::SizeT) : Void*
  # We have to depend on glibc's alternative symbols for malloc because we cannot use dlopen
  # inside malloc, it calls malloc itself
  return LibC.real_malloc(size) if inside_gc?

  enter_gc { LibGC.malloc_uncollectable(size) }
end

fun realloc(ptr : Void*, size : LibC::SizeT) : Void*
  return LibC.real_realloc(ptr, size) if inside_gc? || (gc_initialized? && !GC.is_heap_ptr(ptr))

  enter_gc { LibGC.realloc(ptr, size) }
end

fun calloc(count : LibC::SizeT, size : LibC::SizeT) : Void*
  return LibC.real_calloc(count, size) if inside_gc?

  malloc(count * size)
end

fun free(ptr : Void*)
  # We potentially leak some memory here in case our malloc wrapper couldn't
  # wait for the GC to be initialized and had pass it to the original system malloc,
  # and we get this call while it's still not initialized, so we cannot ask it for whether it
  # allocated this pointer or not.
  # In theory that should only happen from within the GC itself or libraries it calls into,
  # such as pthread_*. We just hope that's little enough memory.

  if gc_initialized?
    GC.is_heap_ptr(ptr) ? enter_gc { LibGC.free(ptr) } : LibC.real_free(ptr)
  end
end

private def correct_alignment(alignment : LibC::SizeT, size : LibC::SizeT)
  # The GC prevents us from aligning to sizes bigger than HLBLOCKSIZE,
  # so for bigger requests we clamp it to HLBLOCKSIZE and allocate enough memory
  # so that we can just shift the start address by the offset between the requested alignment
  # and HLBLOCKSIZE

  # GC constant, target specific but seems to be 4096 for most.
  # Would be nice if we can fetch this somehow
  hlbocksize = LibC::SizeT.new(4096)

  return {alignment, size, LibC::SizeT.new(0)} if alignment <= hlbocksize

  offset = alignment - hlbocksize
  {hlbocksize, size + offset, offset}
end

fun memalign(alignment : LibC::SizeT, size : LibC::SizeT) : Void*
  return LibC.real_memalign(alignment, size) if inside_gc?

  gc_alignment, size, offset = correct_alignment(alignment, size)

  ptr = enter_gc { LibGC.memalign(gc_alignment, size) }
  ptr += offset unless ptr.null? || (ptr.address // alignment) * alignment == ptr.address
  ptr
end

fun posix_memalign(ptr : Void**, alignment : LibC::SizeT, size : LibC::SizeT) : LibC::Int
  return real_posix_memalign(ptr, alignment, size) if inside_gc?

  gc_alignment, size, offset = correct_alignment alignment, size

  ret = enter_gc { LibGC.posix_memalign(ptr, gc_alignment, size) }
  ptr.value = ptr.value + offset unless ret != 0 || ptr.value.null? || (ptr.value.address // alignment) * alignment == ptr.value.address
  ret
end

private def real_posix_memalign(ptr : Void**, alignment : LibC::SizeT, size : LibC::SizeT) : LibC::Int
  handle = open_libc
  address = LibC.dlsym(handle, "posix_memalign")
  function = Proc(Void**, LibC::SizeT, LibC::SizeT, LibC::Int).new(address, Pointer(Void).null)
  function.call(ptr, alignment, size)
end

fun strdup(str : LibC::Char*) : LibC::Char*
  return real_strdup(str) if inside_gc?

  enter_gc { LibGC.strdup(str) }
end

private def real_strdup(str : LibC::Char*) : LibC::Char*
  handle = open_libc
  address = LibC.dlsym(handle, "strdup")
  function = Proc(LibC::Char*, LibC::Char*).new(address, Pointer(Void).null)
  function.call(str)
end

fun strndup(str : LibC::Char*, n : LibC::SizeT) : LibC::Char*
  return real_strndup(str, n) if inside_gc?

  enter_gc { LibGC.strndup(str, n) }
end

private def real_strndup(str : LibC::Char*, n : LibC::SizeT) : LibC::Char*
  handle = open_libc
  address = LibC.dlsym(handle, "strndup")
  function = Proc(LibC::Char*, LibC::SizeT, LibC::Char*).new(address, Pointer(Void).null)
  function.call(str, n)
end

fun pthread_create(thread : LibC::PthreadT*, attr : LibC::PthreadAttrT*, start_func : Void* -> Void*, arg : Void*) : LibC::Int
  # There's one possible issue left here, the GC may call pthread_create for its marker threads
  # directly and not like that being wrapped into GC_pthread_create again. So far in my tests
  # this would only ever happen while inside another GC wrapper function, so with _inside_gc == 1
  # but I'm not certain that's the only possibility

  return real_pthread_create(thread, attr, start_func, arg) if inside_gc?

  enter_gc { LibGC.pthread_create(thread, attr, start_func, arg) }
end

fun real_pthread_create(thread : LibC::PthreadT*, attr : LibC::PthreadAttrT*, start_func : Void* -> Void*, arg : Void*) : LibC::Int
  handle = open_libpthread
  address = LibC.dlsym(handle, "pthread_create")

  # Crystal bug: We cannot declare the type of start_func as Void* -> Void* here because then crystal types it as
  # Proc rather than a function pointer, clobbering the next argument with the closure data. This is largely
  # because Crystal lacks a distinct type for function pointers.
  # Crystal bug: we cannot define this as a def because then start_func gets typed to something that breaks the workaround,
  # let's just hope no library ever defines the same symbol or if it does it expects the same semantics we provide here
  function = Proc(LibC::PthreadT*, LibC::PthreadAttrT*, Void*, Void*, LibC::Int).new(address, Pointer(Void).null)

  # Crystal bug: Proc#pointer is broken for C funcs
  start_func_pointer = pointerof(start_func).as(Void**).value

  function.call(thread, attr, start_func_pointer, arg)
end

fun pthread_join(thread : LibC::PthreadT, value : Void**) : LibC::Int
  return real_pthread_join(thread, value) if inside_gc?

  enter_gc { LibGC.pthread_join(thread, value) }
end

def real_pthread_join(thread : LibC::PthreadT, value : Void**) : LibC::Int
  handle = open_libpthread
  address = LibC.dlsym(handle, "pthread_join")
  function = Proc(LibC::PthreadT, Void**, LibC::Int).new(address, Pointer(Void).null)
  function.call(thread, value)
end

fun pthread_detach(thread : LibC::PthreadT) : LibC::Int
  return real_pthread_detach(thread) if inside_gc?

  enter_gc { LibGC.pthread_detach(thread) }
end

private def real_pthread_detach(thread : LibC::PthreadT) : LibC::Int
  handle = open_libpthread
  address = LibC.dlsym(handle, "pthread_detach")
  function = Proc(LibC::PthreadT, LibC::Int).new(address, Pointer(Void).null)
  function.call(thread)
end

fun pthread_sigmask(how : LibC::Int, set : LibC::SigsetT*, oldset : LibC::SigsetT*) : LibC::Int
  return real_pthread_sigmask(how, set, oldset) if inside_gc?

  LibGC._inside_gc = 1
  ret = LibGC.pthread_sigmask(how, set, oldset)
  LibGC._inside_gc = 0
  ret
end

private def real_pthread_sigmask(how : LibC::Int, set : LibC::SigsetT*, oldset : LibC::SigsetT*) : LibC::Int
  handle = open_libpthread
  address = LibC.dlsym(handle, "pthread_sigmask")
  function = Proc(LibC::Int, LibC::SigsetT*, LibC::SigsetT*, LibC::Int).new(address, Pointer(Void).null)
  function.call(how, set, oldset)
end

fun pthread_exit(value : Void*)
  return real_pthread_exit(value) if inside_gc?

  enter_gc { LibGC.pthread_exit(value) }
end

private def real_pthread_exit(value : Void*)
  handle = open_libpthread
  address = LibC.dlsym(handle, "pthread_exit")
  function = Proc(Void*, Void).new(address, Pointer(Void).null)
  function.call(value)
end

fun pthread_cancel(thread : LibC::PthreadT) : LibC::Int
  return real_pthread_cancel(thread) if inside_gc?

  enter_gc { LibGC.pthread_cancel(thread) }
end

private def real_pthread_cancel(thread : LibC::PthreadT) : LibC::Int
  handle = open_libpthread
  address = LibC.dlsym(handle, "pthread_cancel")
  function = Proc(LibC::PthreadT, LibC::Int).new(address, Pointer(Void).null)
  function.call(thread)
end
