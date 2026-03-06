import { defineConfig, devices } from '@playwright/test';
import * as dotenv from 'dotenv';
import * as path from 'path';

dotenv.config({ path: path.resolve(__dirname, '.env') });

const baseDomain = process.env.E2E_BASE_DOMAIN || 'dev.example.com';
const userCount = Number(process.env.LOAD_USER_COUNT || 20);

export default defineConfig({
  testDir: './tests',
  fullyParallel: true,
  forbidOnly: true,
  retries: 0,
  workers: userCount,
  reporter: [
    ['html', { open: 'never' }],
    ['list'],
  ],

  // Generous timeouts — load tests are about "does it work under load", not speed
  timeout: 180_000,

  use: {
    baseURL: `https://account.${baseDomain}`,
    ignoreHTTPSErrors: true,
    screenshot: 'only-on-failure',
    trace: 'retain-on-failure',
    actionTimeout: 30_000,
    navigationTimeout: 60_000,
  },

  projects: [
    {
      name: 'load',
      use: {
        ...devices['Desktop Chrome'],
        headless: true,
        launchOptions: {
          args: [
            '--use-fake-ui-for-media-stream',
            '--use-fake-device-for-media-stream',
            '--disable-gpu',
          ],
        },
      },
    },
    {
      name: 'load-headed',
      use: {
        ...devices['Desktop Chrome'],
        headless: false,
        launchOptions: {
          args: [
            '--use-fake-ui-for-media-stream',
            '--use-fake-device-for-media-stream',
          ],
        },
      },
    },
  ],
});
