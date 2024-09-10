/** @type {import('tailwindcss').Config} */
module.exports = {
  content: [
    "./src/**/*.{gleam,mjs}",
    "./build/dev/javascript/**/*.mjs",
    "./build/dev/static/**/*.{html,mjs,css}",
  ],
  theme: {
    extend: {},
  },
  plugins: [],
  important: true,
}
