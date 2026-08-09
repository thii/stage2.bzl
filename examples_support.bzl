"""Repository-bound source labels used by the external examples workspace."""

visibility("public")

BINUTILS_CONFIGURE = Label("@binutils_src//:configure")
BINUTILS_SRCS = Label("@binutils_src//:srcs")
GCC_COMBINED_CONFIGURE = Label("@gcc_combined_src//:configure")
GCC_COMBINED_SRCS = Label("@gcc_combined_src//:srcs")
LLVM_CMAKE_LISTS = Label("@llvm_src//:llvm/CMakeLists.txt")
LLVM_SRCS = Label("@llvm_src//:srcs")
