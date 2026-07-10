# public/

Acá va el frontend: HTML + CSS + JS plano, servido como PWA por Netlify. Estructura planeada (se crea a medida que avanzan las fases, no hay código todavía):

```
public/
├── index.html              (login)
├── manifest.json           (Fase 14)
├── service-worker.js       (Fase 14)
├── icons/                  (íconos PWA)
├── css/
│   └── chaupapel.css
├── js/
│   ├── supabaseClient.js   (conexión y utilidades compartidas)
│   ├── auth.js
│   ├── productos.js
│   ├── proveedores.js
│   ├── ventas.js
│   ├── caja.js
│   ├── fiado.js
│   └── ...
└── *.html                  (una pantalla por módulo: productos.html, ventas.html, caja.html, etc.)
```

Cada módulo funcional tiene su propio archivo JS (sección 18 de `spec.md`) para no mezclar toda la lógica en un solo archivo gigante.
