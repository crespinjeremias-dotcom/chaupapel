// Servidor estatico minimo para probar public/ en local (sin dependencias).
// Lo usa .claude/launch.json -- reemplaza al "python -m http.server", que no
// esta instalado en esta maquina.
import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const raiz = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', 'public');
const puerto = Number(process.env.PORT) || 8888;

const TIPOS = {
  '.html': 'text/html; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.json': 'application/json; charset=utf-8',
  '.png': 'image/png',
  '.svg': 'image/svg+xml',
};

http
  .createServer((req, res) => {
    let ruta = decodeURIComponent(req.url.split('?')[0]);
    if (ruta.endsWith('/')) ruta += 'index.html';
    const archivo = path.join(raiz, ruta);
    // no salirse de public/ con rutas tipo ../
    if (!archivo.startsWith(raiz)) {
      res.writeHead(403).end();
      return;
    }
    fs.readFile(archivo, (err, datos) => {
      if (err) {
        res.writeHead(404).end('No encontrado');
        return;
      }
      res.writeHead(200, { 'Content-Type': TIPOS[path.extname(archivo)] || 'application/octet-stream', 'Cache-Control': 'no-store' });
      res.end(datos);
    });
  })
  .listen(puerto, () => console.log(`public/ en http://localhost:${puerto}`));
