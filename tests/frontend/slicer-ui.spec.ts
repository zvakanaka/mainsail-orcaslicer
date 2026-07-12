import { test, expect, type Page, type Route } from '@playwright/test';

type Profiles = { printer: string[]; process: string[]; filament: string[] };

interface MockState {
  healthOk: boolean;
  profiles: Profiles;
  sliceResponse: { status: number; body: unknown };
  requests: { method: string; path: string; body: unknown }[];
}

function defaultState(overrides: Partial<MockState> = {}): MockState {
  return {
    healthOk: true,
    profiles: { printer: [], process: [], filament: [] },
    sliceResponse: {
      status: 200,
      body: { filename: 'cube.gcode', slice_time: '5.0' },
    },
    requests: [],
    ...overrides,
  };
}

async function mockApi(page: Page, state: MockState) {
  await page.route('**/server/orcaslicer/**', async (route: Route) => {
    const req = route.request();
    const url = new URL(req.url());
    const path = url.pathname.replace(/^.*\/server\/orcaslicer/, '');
    const method = req.method();

    let body: unknown = undefined;
    try {
      body = req.postData() ? JSON.parse(req.postData()!) : undefined;
    } catch {
      body = req.postData();
    }
    state.requests.push({ method, path, body });

    if (path === '/health') {
      if (state.healthOk) {
        return route.fulfill({ json: { status: 'ok' } });
      }
      return route.fulfill({ status: 503, json: { error: 'offline' } });
    }

    const profileMatch = path.match(/^\/profiles\/(printer|process|filament)$/);
    if (profileMatch && method === 'GET') {
      return route.fulfill({ json: state.profiles[profileMatch[1] as keyof Profiles] });
    }
    if (profileMatch && method === 'POST') {
      const type = profileMatch[1] as keyof Profiles;
      const filename = (body as { filename: string }).filename;
      const name = filename.replace(/\.json$/, '');
      state.profiles[type] = [...state.profiles[type], name];
      return route.fulfill({ status: 201, json: { uploaded: true } });
    }

    const itemMatch = path.match(/^\/profiles\/(printer|process|filament)\/(.+)$/);
    if (itemMatch && method === 'DELETE') {
      const type = itemMatch[1] as keyof Profiles;
      const name = decodeURIComponent(itemMatch[2]);
      state.profiles[type] = state.profiles[type].filter((n) => n !== name);
      return route.fulfill({ json: { deleted: true } });
    }

    if (path === '/slice' && method === 'POST') {
      return route.fulfill({
        status: state.sliceResponse.status,
        json: state.sliceResponse.body,
      });
    }

    return route.fulfill({ status: 404, json: { error: `unhandled ${method} ${path}` } });
  });
}

async function gotoUi(page: Page, state: MockState) {
  // Each test gets a fresh browser context, so localStorage starts empty —
  // no explicit clearing needed.
  await mockApi(page, state);
  await page.goto('/slicer_ui.html');
}

test('health indicator shows Connected when the API is reachable', async ({ page }) => {
  const state = defaultState({ healthOk: true });
  await gotoUi(page, state);
  await expect(page.locator('#health-indicator')).toHaveText('Connected');
});

test('health indicator shows Offline and a status card when the API is unreachable', async ({
  page,
}) => {
  const state = defaultState({ healthOk: false });
  await gotoUi(page, state);
  await expect(page.locator('#health-indicator')).toHaveText('Offline');
  await expect(page.locator('.status-card.offline')).toContainText('Cannot reach slicer service');
});

test('profile list renders uploaded profiles and populates the dropdowns', async ({ page }) => {
  const state = defaultState({
    profiles: { printer: ['my-printer'], process: ['0.2mm-standard'], filament: ['pla'] },
  });
  await gotoUi(page, state);

  await expect(page.locator('#profile-list .profile-item .name')).toHaveText('my-printer');
  await expect(page.locator('#sel-printer')).toContainText('my-printer');
  await expect(page.locator('#sel-process')).toContainText('0.2mm-standard');
  await expect(page.locator('#sel-filament')).toContainText('pla');
});

test('switching tabs shows profiles for that category', async ({ page }) => {
  const state = defaultState({
    profiles: { printer: ['my-printer'], process: ['0.2mm-standard'], filament: [] },
  });
  await gotoUi(page, state);

  await page.locator('.tab[data-type="process"]').click();
  await expect(page.locator('#profile-list .profile-item .name')).toHaveText('0.2mm-standard');

  await page.locator('.tab[data-type="filament"]').click();
  await expect(page.locator('#profile-list')).toContainText('No profiles uploaded');
});

test('uploading a profile sends filename/content and refreshes the list', async ({ page }) => {
  const state = defaultState();
  await gotoUi(page, state);

  await page.locator('#profile-file-input').setInputFiles({
    name: 'my-printer.json',
    mimeType: 'application/json',
    buffer: Buffer.from('{"nozzle_diameter": [0.4]}'),
  });

  await expect(page.locator('#profile-list .profile-item .name')).toHaveText('my-printer');

  const uploadReq = state.requests.find((r) => r.method === 'POST' && r.path === '/profiles/printer');
  expect(uploadReq).toBeTruthy();
  expect(uploadReq!.body).toMatchObject({
    filename: 'my-printer.json',
    content: '{"nozzle_diameter": [0.4]}',
  });
});

test('deleting a profile removes it from the list', async ({ page }) => {
  const state = defaultState({
    profiles: { printer: ['my-printer'], process: [], filament: [] },
  });
  await gotoUi(page, state);

  page.once('dialog', (dialog) => dialog.accept());
  await page.locator('.profile-item .btn-danger').click();

  await expect(page.locator('#profile-list')).toContainText('No profiles uploaded');
  const deleteReq = state.requests.find((r) => r.method === 'DELETE');
  expect(deleteReq?.path).toBe('/profiles/printer/my-printer');
});

test('slice button stays disabled until a model and all three profiles are selected', async ({
  page,
}) => {
  const state = defaultState({
    profiles: { printer: ['p1'], process: ['pr1'], filament: ['f1'] },
  });
  await gotoUi(page, state);

  const btn = page.locator('#btn-slice');
  await expect(btn).toBeDisabled();

  await page.locator('#model-file-input').setInputFiles({
    name: 'cube.stl',
    mimeType: 'application/octet-stream',
    buffer: Buffer.from('fake-stl-bytes'),
  });
  await expect(page.locator('#model-filename')).toHaveText('cube.stl');
  await expect(btn).toBeDisabled();

  await page.locator('#sel-printer').selectOption('p1');
  await expect(btn).toBeDisabled();
  await page.locator('#sel-process').selectOption('pr1');
  await expect(btn).toBeDisabled();
  await page.locator('#sel-filament').selectOption('f1');
  await expect(btn).toBeEnabled();
});

async function selectAllAndSlice(page: Page) {
  await page.locator('#model-file-input').setInputFiles({
    name: 'cube.stl',
    mimeType: 'application/octet-stream',
    buffer: Buffer.from('fake-stl-bytes'),
  });
  await page.locator('#sel-printer').selectOption('p1');
  await page.locator('#sel-process').selectOption('pr1');
  await page.locator('#sel-filament').selectOption('f1');
  await page.locator('#btn-slice').click();
}

test('slicing sends base64 model data and selected profile names, shows success', async ({
  page,
}) => {
  const state = defaultState({
    profiles: { printer: ['p1'], process: ['pr1'], filament: ['f1'] },
    sliceResponse: { status: 200, body: { filename: 'cube.gcode', slice_time: '3.2' } },
  });
  await gotoUi(page, state);
  await selectAllAndSlice(page);

  await expect(page.locator('.status-card.success')).toContainText('cube.gcode');
  await expect(page.locator('.status-card.success')).toContainText('3.2');

  const sliceReq = state.requests.find((r) => r.method === 'POST' && r.path === '/slice');
  expect(sliceReq).toBeTruthy();
  const sliceBody = sliceReq!.body as Record<string, string>;
  expect(sliceBody.printer).toBe('p1');
  expect(sliceBody.process).toBe('pr1');
  expect(sliceBody.filament).toBe('f1');
  expect(sliceBody.model_filename).toBe('cube.stl');
  expect(Buffer.from(sliceBody.model_data, 'base64').toString()).toBe('fake-stl-bytes');
});

test('slice failure shows an error status card', async ({ page }) => {
  const state = defaultState({
    profiles: { printer: ['p1'], process: ['pr1'], filament: ['f1'] },
    sliceResponse: { status: 500, body: { error: 'slicer crashed' } },
  });
  await gotoUi(page, state);
  await selectAllAndSlice(page);

  await expect(page.locator('.status-card.error')).toContainText('slicer crashed');
});

test('profile and bed-type selections persist across reload', async ({ page }) => {
  const state = defaultState({
    profiles: { printer: ['p1'], process: ['pr1'], filament: ['f1'] },
  });
  await gotoUi(page, state);

  await page.locator('#sel-printer').selectOption('p1');
  await page.locator('#sel-process').selectOption('pr1');
  await page.locator('#sel-filament').selectOption('f1');
  await page.locator('#sel-bed-type').selectOption('Cool Plate');

  // Reload without clearing localStorage this time.
  await mockApi(page, state);
  await page.reload();

  await expect(page.locator('#sel-printer')).toHaveValue('p1');
  await expect(page.locator('#sel-process')).toHaveValue('pr1');
  await expect(page.locator('#sel-filament')).toHaveValue('f1');
  await expect(page.locator('#sel-bed-type')).toHaveValue('Cool Plate');
});
