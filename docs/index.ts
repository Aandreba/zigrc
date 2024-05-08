const server = Bun.serve({
  fetch(req) {
    const url = new URL(req.url);
    const path = url.pathname === "/" ? "/index.html" : url.pathname;
    return new Response(Bun.file(`./zig-out/docs${path}`));
  },
});

console.log(`Server started at ${server.port}`);
