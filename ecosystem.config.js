module.exports = {
  apps: [
    {
      name: 'umami',
      script: 'pnpm',
      args: 'start',
      env: {
        PORT: 3060,
        NODE_ENV: 'production',
      },
    },
  ],
};
