import { PHASE_DEVELOPMENT_SERVER, PHASE_PRODUCTION_BUILD } from "next/constants.js";

async function devRewrites() {
  return [
    {
      source: "/api/:path*",
      destination: "http://localhost:8080/api/:path*",
    },
  ];
}

export default function nextConfig(phase) {
  if (phase === PHASE_DEVELOPMENT_SERVER) {
    return {
      rewrites: devRewrites,
    };
  }
  if (phase === PHASE_PRODUCTION_BUILD) {
    return {
      output: "standalone",
    };
  }
  return {};
}
