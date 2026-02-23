/** @type {import('tailwindcss').Config} */
module.exports = {
  content: ['./views/**/*.ejs'],
  theme: {
    extend: {
      fontFamily: {
        sans: ['Figtree', 'system-ui', '-apple-system', 'sans-serif'],
      },
      colors: {
        ash: '#F3E8D6',
        coal: '#141511',
        'ghost-fern': { DEFAULT: '#A7AE8D', dark: '#8A9475' },
        cinder: '#A64330',
        sage: { DEFAULT: '#A7AE8D', dark: '#8A9475' },
        cream: '#F3E8D6',
        'warm-gray': '#6B6B6B',
      },
    },
  },
  plugins: [],
};
