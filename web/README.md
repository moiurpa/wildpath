# WildPath web app

A static website: map, your location, one-tap reporting, risky roads and drive-mode
warnings. Put these files on any web host (GitHub Pages, Netlify) to get a link.

- With no server behind it, it runs in **demo mode**: sample animals are shown and
  new reports are saved on that phone only.
- With the WildPath server (`/server`) running at the same address, reports are
  shared between everyone.
- To use Google Maps instead of OpenStreetMap, put your key in `config.js`
  (`googleMapsKey`) and restrict the key to your website's address in Google Cloud.
