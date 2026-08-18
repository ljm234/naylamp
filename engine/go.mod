module naylamp/engine

go 1.26

// This line does NOT govern any build made from the workspace, which is every
// build of this tree and every step of CI. In workspace mode the go command
// never consults a module's toolchain line: measured with only go1.26.5 on the
// path, go.work asking for 1.26.5 and this file asking for 1.26.6 resolves to
// 1.26.5. What governs is the toolchain line of ../go.work, and that is where a
// version bump goes first. This one is kept in step with it because it is what
// the module declares to anyone who builds it on its own, with GOWORK=off or
// outside this repository, where it does govern.
toolchain go1.26.6
