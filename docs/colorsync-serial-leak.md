# Fuga de ColorSync (colorsyncd al 100 %, perfiles .icc que se acumulan): causa raíz y fix

Hallazgo hecho el 2026-09-02 mientras se implementaban displays virtuales nativos en
**remotedesk** (mismo `CGVirtualDisplay`, mismo síntoma). **Aplicado y verificado en
SimpleDisplay el mismo día** en una VM Tart limpia (`simpledisplay-test`), 100 ciclos
crear/destruir con el build con fix y otros 100 con el build anterior como contraste.
Evidencia: `docs/colorsync-stress/` (scripts y logs).

## Síntoma (el que SimpleDisplay venía parcheando)

- Cada display virtual creado dejaba un `.icc` nuevo en `/Library/ColorSync/Profiles/Displays`
  (root:wheel — la app no puede borrarlos sin privilegios).
- `colorsyncd` / `displayservices` quedaban al ~100 % de CPU de forma sostenida.
- Medido en remotedesk con el código equivalente al que tenía SimpleDisplay
  (serial aleatorio): **100 ciclos → 56 `.icc` nuevos + CPU al 100 %**.
- Lo que SimpleDisplay tenía para esto eran paliativos: `assignSRGBProfile`,
  `scheduleColorSyncCleanup`, `unregisterColorSyncDevice`, `removeICCProfile` (osascript
  con password) y el botón "fix color profiles" que mata daemons y borra perfiles con sudo.

## Causa raíz

`VirtualDisplayService.createVirtualDisplay` hacía:

```swift
let serial = UInt32.random(in: 1...UInt32.max)
```

ColorSync identifica un display por **vendorID / productID / serialNumber** (de ahí sale
el UUID del dispositivo). Con un serial aleatorio, cada `CGVirtualDisplay` es un monitor
**nuevo** para macOS: genera un perfil nuevo, lo registra, y revalida la pila creciente
para siempre. No es un bug de macOS: es identidad de dispositivo distinta en cada create.

## Fix

Serial **estable por slot**: el N-ésimo display virtual simultáneo usa siempre el serial N
(el más bajo libre, 1..4095). Al destruirlo, se libera el slot. Así el mismo "monitor"
reaparece con la misma identidad y macOS **reusa** su perfil: la cantidad de `.icc` queda
acotada por el máximo de displays simultáneos (1 display → 1 perfil, siempre el mismo).
Asignar sRGB solo NO alcanza (se probó); lo que corta la fuga es la identidad estable.

Implementación en `Sources/SimpleDisplay/Services/VirtualDisplayService.swift`:

- `allocateSerial()` / `releaseSerial(for:)` sobre `usedSerials` + `serialByDisplay`.
  El slot se libera en `removeVirtualDisplay`, `removeAll`, `pruneTerminatedDisplays`
  y en los dos caminos de error de `createVirtualDisplay` (wrapper nil / applyWidth falla,
  donde además ahora se invalida el wrapper).
- Como los displays se restauran al arrancar en el orden guardado, cada display persistido
  recupera el mismo serial (y el mismo perfil) también entre reinicios de la app.
- Podado: `scheduleColorSyncCleanup` (borrar el `.icc` solo obliga a regenerarlo en el
  próximo create), `unregisterColorSyncDevice` (AuthorizationCreate por XPC síncrono:
  colgaba la app y encola un diálogo de password) y `removeICCProfile` (osascript con
  password). Se mantienen `assignSRGBProfile` (inocuo) y el botón "fix color profiles"
  de Ajustes, como recuperación para máquinas que ya acumularon perfiles con builds viejos.

## Verificación (2026-09-02, VM Tart limpia)

VM `simpledisplay-test`: clon de `ghcr.io/cirruslabs/macos-tahoe-base:latest`
(macOS 26.6.2, SIP off, admin/admin) en `TART_HOME=/Volumes/sam-ex/macOS-tart`.
Cada ciclo: `simpledisplayctl create --width 1280 --height 720 --name stressN` → 2 s →
`simpledisplayctl remove --name stressN` → 2 s, rotando tres nombres (`stress0..2`) para
comprobar que el nombre no forma parte de la identidad. Medición cada 10 ciclos: cantidad
de `.icc` en `/Library/ColorSync/Profiles/Displays` y CPU sumada de `colorsyncd` +
`colorsync.displayservices`. Se corrió primero el build con fix (VM virgen) y después el
build anterior en la misma VM (el orden inverso contaminaría la medición del fix).

| Build | Ciclos | `.icc` al inicio | `.icc` al final | CPU colorsync (todas las muestras) |
|---|---|---|---|---|
| **Con fix** (serial estable) | 100 | 2 (VM + 1 de SimpleDisplay) | **2** | **0 %** |
| Sin fix (HEAD b6e1b47, serial aleatorio) | 100 | 2 | **98** (+96, ~1 por ciclo) | 0 % en las muestras; latencia por ciclo ×3 (ver nota) |

Detalles del build con fix (`docs/colorsync-stress/stress-100-despues.log`):

- El único `.icc` de SimpleDisplay conservó el UUID `571D422E-…` en los 100 ciclos aunque
  el display se llamara `smoke`, `stress0/1/2` o `verif`: macOS solo renombra el archivo
  al último nombre. **El nombre no cambia la identidad**; solo importa vendor/product/serial.
- Se confirmó con `simpledisplay://status` que cada create produce un display virtual real
  (1280×720, `virtual: true`) y que el remove lo quita.
- RSS de la app estable (71–74 MB) durante la corrida.

Contraste sin fix (`docs/colorsync-stress/stress-100-antes.log`):

- De 2 a **98** `.icc` en 100 ciclos: un UUID distinto por create (`stress0-…`, `stress1-…`,
  `stress2-…`, 32 archivos por nombre). Identidad nueva en cada create, como predice la causa raíz.
- Las muestras de CPU de `colorsyncd`/`displayservices` dieron 0 % también sin fix: `ps` reporta
  un promedio reciente, y en los 15 minutos de esta corrida el bucle al 100 % visto en remotedesk
  no llegó a manifestarse en esta VM. El costo sí se ve en la latencia: los primeros 10 ciclos
  tardaron 41 s y los últimos 10 unos 120 s (con fix: ~44 s constantes durante los 100),
  consistente con ColorSync reprocesando una pila cada vez mayor en cada cambio de displays.
- La VM quedó contaminada por esta corrida (los `stress*.icc` se borraron a mano después, pero
  el registro de dispositivos de ColorSync conserva las entradas): para una medición limpia del
  fix, clonar una VM nueva.

### Reproducir

```sh
# VM limpia en el TART_HOME del disco externo (HFS+: el clone copia ~47 GB, ~6 min)
export TART_HOME=/Volumes/sam-ex/macOS-tart
tart clone ghcr.io/cirruslabs/macos-tahoe-base:latest simpledisplay-test
tart set simpledisplay-test --random-mac   # las VMs clonadas de la misma imagen comparten MAC
tart run simpledisplay-test &              # con ventana: --no-graphics deja al guest sin display
IP=$(tart ip simpledisplay-test)

make bundle && codesign --force --deep --sign - .build/SimpleDisplay.app
docs/colorsync-stress/deploy.sh $IP .build/SimpleDisplay.app .build/apple/Products/Release/simpledisplayctl
docs/colorsync-stress/stress.sh $IP 100 "con fix" /tmp/stress.log
```

Esperado: `.icc` constante (1 de la VM + 1 de SimpleDisplay) y CPU 0 % en todas las
muestras. Con el build anterior, `.icc` crece con los ciclos.

## Otros hallazgos de macOS 26 que pueden aplicar a SimpleDisplay (enable/disable/main)

- Destruir un `CGVirtualDisplay` que fue **master de un espejo** deja un display fantasma
  permanente: remotedesk lo cachea deshabilitado (`CGSConfigureDisplayEnabled` vía
  `dlsym` de SkyLight) y lo recicla en vez de destruirlo.
- `applySettings` no conmuta el modo en displays **main o espejados** sin un commit de
  transacción de configuración ("nudge"); pero el nudge en un display destruible también
  lo vuelve fantasma → hacerlo solo cuando es main/master.
- Encadenar configs de espejo sin esperar el asentamiento produce ciclos con **0 displays
  activos**: verificar `CGGetActiveDisplayList` antes del siguiente paso.

Referencia de implementación: `remotedesk/engine/rustdesk/src/platform/macos.mm`
(sección "remotedesk: displays virtuales") y `remotedesk/docs/pruebas/vdisplay-vm/`.
