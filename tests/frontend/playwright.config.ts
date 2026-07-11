import { defineConfig } from '@playwright/test';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const SRC_DIR = path.resolve(__dirname, '../../src');
const PORT = 8934;

export default defineConfig({
  testDir: '.',
  fullyParallel: true,
  reporter: 'list',
  use: {
    baseURL: `http://127.0.0.1:${PORT}`,
  },
  webServer: {
    command: `python3 -m http.server ${PORT} --directory "${SRC_DIR}" --bind 127.0.0.1`,
    url: `http://127.0.0.1:${PORT}/slicer_ui.html`,
    reuseExistingServer: !process.env.CI,
  },
});
