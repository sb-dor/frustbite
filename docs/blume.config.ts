import { defineConfig } from "blume";

export default defineConfig({
  title: "Frustbite",
  description: "Read and edit audio from Dart, powered by Rust.",
  content: {
    root: "content",
  },
  github: {
    owner: "sb-dor",
    repo: "frustbite",
    dir: "docs",
  },
  agents: {
    llmsTxt: true,
  },
  // Blume 2: `{ site, base }` is the static build for any host (GitHub Pages).
  deployment: {
    site: "https://sb-dor.github.io",
    base: "/frustbite",
  },
});
