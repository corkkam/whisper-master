import adapter from '@sveltejs/adapter-vercel';
import { vitePreprocess } from '@sveltejs/vite-plugin-svelte';

/** @type {import('@sveltejs/kit').Config} */
const config = {
  preprocess: vitePreprocess(),
  kit: {
    // Deployed on Vercel; the API routes + SSR run as Node serverless functions.
    adapter: adapter({ runtime: 'nodejs20.x' })
  }
};

export default config;
