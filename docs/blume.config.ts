import { defineConfig } from "blume";

export default defineConfig({
  title: "Frustbite",
  description: "Read audio metadata, waveforms and PCM from Dart, powered by Rust.",
  content: {
    root: "content",
  },
  github: {
    owner: "sb-dor",
    repo: "frustbite",
    dir: "docs",
  },
  ai: {
    llmsTxt: true,
  },
  deployment: {
    output: "static",
    site: "https://sb-dor.github.io",
    base: "/frustbite",
  },
});
