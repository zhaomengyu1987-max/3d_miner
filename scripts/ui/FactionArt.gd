extends RefCounted

static var _cache := {}


static func incident(fid: String) -> Texture2D:
	if _cache.has(fid): return _cache[fid]
	var color := "75cbe6" if fid == "southern" else "edac73"
	var svg := '<svg xmlns="http://www.w3.org/2000/svg" width="640" height="260" viewBox="0 0 640 260"><defs><linearGradient id="space" x2="1" y2="1"><stop stop-color="#142535"/><stop offset="1" stop-color="#050b13"/></linearGradient></defs><rect width="640" height="260" rx="12" fill="url(#space)"/><g fill="#8aabbd"><circle cx="40" cy="44" r="1"/><circle cx="160" cy="30" r="2"/><circle cx="260" cy="56" r="1"/><circle cx="470" cy="32" r="1"/><circle cx="590" cy="72" r="2"/><circle cx="540" cy="218" r="1"/><circle cx="72" cy="220" r="2"/></g><g stroke="#527386" stroke-width="3" fill="#263b4c"><path d="m300 70 60-30 55 30v106l-55 35-60-35Z"/><path d="m300 70 60 32 55-32M360 102V211"/><path d="M308 128H245V148H308M415 128H478V148H415"/><circle cx="360" cy="131" r="19" fill="#81c8de"/></g><g fill="#%s" stroke="#c8d4db" stroke-width="2"><path d="m510 73 17 20 43 7-43 9-17 20 4-28Z"/><path d="m516 157 15 14 34 5-34 8-15 18 3-26Z"/></g><path d="m115 109 28-9 31 15-8 23-30 9-29-15Z" fill="#7b9aa8"/><path d="m169 125 23 8-4 18-14-5Z" fill="#536b7b"/><path d="M200 110 222 99M207 150 223 162M140 75 143 92" stroke="#e08c64" stroke-width="4"/><circle cx="182" cy="129" r="30" fill="#e07845" opacity=".13"/><path d="m490 103-286 23M494 178 204 139" stroke="#f49070" stroke-width="2" stroke-dasharray="10 8" opacity=".6"/><path d="m108 179 67 0M108 189H152" stroke="#%s" stroke-width="3"/><path d="m589 19 23 0 0 23M28 19H16V42M16 230V242H40M600 242H623V218" fill="none" stroke="#53778b" stroke-width="2"/></svg>' % [color, color]
	var image := Image.new()
	image.load_svg_from_string(svg)
	var texture := ImageTexture.create_from_image(image)
	_cache[fid] = texture
	return texture
