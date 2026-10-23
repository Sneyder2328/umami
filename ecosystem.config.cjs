// PM2 process for Umami on the VPS. Runs Next directly (not `pnpm start`), so the
// process doesn't depend on the pnpm version installed globally — this project
// pins pnpm 12 in `engines` — or on the absolute path PM2 would store for it.
module.exports = {
  apps: [
    {
      name: 'umami',
      script: './node_modules/next/dist/bin/next',
      args: 'start',
      cwd: __dirname,
      env: {
        PORT: 3060,
        NODE_ENV: 'production',
      },
    },
  ],
};
