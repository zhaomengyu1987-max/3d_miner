extends RefCounted

## Small vector illustrations, cached once per good; no thumbnail cameras or extra imports.
const COLORS := {
	"commonA": "a9becb", "commonB": "b7a08a", "commonC": "7fcee0", "commonD": "a2abb3", "commonE": "9c8f78",
	"rareA": "65b7ff", "rareB": "ba90ef", "rareC": "f3c76d", "rareD": "f47781", "rareE": "e4d386", "fuel": "83e7f3",
	"truss": "93bac8", "cabin": "b4c9d4", "ecu": "75d5c5", "fueltank": "86bbec",
	"kineticAmmo": "dfbd7f", "thermalMissile": "f7a57b", "heavyTorpedo": "ed9271", "plasmaAmmo": "bb94f5",
	"armorPlate": "9bbbd0", "resistanceMembrane": "8ecbe8", "nanoArmorRepairer": "83d6a8",
	"smallArms": "b3bac8", "heavyArms": "b3bb8f", "nanoRepair": "6fd7d0",
	"eq_power_mk1": "eab573", "eq_elec_mk1": "7fc8ef", "eq_weapon_mk1": "dc9c83", "eq_defense_mk1": "a4b2e2",
	"longbow": "b7cbd7", "raven": "9caed0", "ram": "c9a98b", "logistics": "a6c4ba",
}

const SYMBOLS := {
	"fuel": '<path d="M15 49 21 24 31 30 37 10 53 22 58 49 38 62Z" fill="url(#surface)"/><path d="M21 24 25 48 38 62 37 10M37 30 53 22 44 50 38 62M15 49 25 48 44 50 58 49" fill="none" stroke="#dcfbff" stroke-width="1.4" opacity=".75"/>',
	"truss": '<path d="M13 24 37 13 59 25 36 37ZM13 24V49L36 61V37M36 61 59 49V25" fill="none" stroke="url(#surface)" stroke-width="4" stroke-linejoin="round"/><path d="M15 26 34 58M15 47 34 39M38 38 57 48M38 58 57 27M17 24 54 25M35 16 36 34" stroke="#bbdce7" stroke-width="2"/>',
	"cabin": '<path d="M15 25 37 15 58 25V49L36 60 15 49Z" fill="url(#surface)" stroke="#d1e5ec" stroke-width="1"/><path d="M15 25 36 36 58 25M36 36V60" fill="none" stroke="#334c5b" stroke-width="3"/><path d="M20 32V45L29 50V37ZM42 38V50L52 45V33Z" fill="#365567"/><path d="m22 23 15-6 14 7-15 7Z" fill="#d1e1e8" opacity=".6"/>',
	"ecu": '<rect x="17" y="18" width="38" height="38" rx="4" fill="url(#surface)"/><rect x="24" y="25" width="24" height="24" rx="2" fill="#162e39" stroke="#b8f7e4"/><path d="M29 29H43V43H29ZM10 25H17M10 36H17M10 47H17M55 25H62M55 36H62M55 47H62M25 11V18M36 11V18M47 11V18M25 56V63M36 56V63M47 56V63" fill="none" stroke="#89ccb9" stroke-width="3"/><path d="m31 35 4 4 7-8" fill="none" stroke="#acffe0" stroke-width="2"/>',
	"fueltank": '<rect x="23" y="12" width="27" height="47" rx="12" fill="url(#surface)" stroke="#d1e9ff"/><ellipse cx="36.5" cy="21" rx="13.5" ry="7" fill="#d0dfe8"/><path d="M23 29H50M23 47H50M20 59H53M28 10H45" stroke="#324b63" stroke-width="4"/><rect x="31" y="33" width="11" height="10" rx="2" fill="#8ae0fc"/>',
	"kineticAmmo": '<path d="M17 54V29L23 17 29 29V54ZM31 58V22L37 10 43 22V58ZM45 54V29L51 17 57 29V54Z" fill="url(#surface)" stroke="#f4d9a2" stroke-width="1.3"/><path d="M17 45H29M31 49H43M45 45H57M17 53H29M31 57H43M45 53H57" stroke="#826344" stroke-width="3"/>',
	"thermalMissile": '<path d="M19 55V27L27 13 35 27V55ZM39 59V31L47 17 55 31V59Z" fill="url(#surface)" stroke="#e7ddd2"/><path d="m19 45-6 12h12M35 45l6 12H29M39 49l-6 12h12M55 49l6 12H49" fill="#a2afbc"/><path d="M19 29H35M39 33H55" stroke="#ee7a58" stroke-width="5"/>',
	"heavyTorpedo": '<path d="M24 53V29Q24 20 36 9 48 20 48 29V53L36 61Z" fill="url(#surface)" stroke="#ead9ca" stroke-width="1.5"/><path d="M24 43 14 60 29 55M48 43 58 60 43 55" fill="#74899b"/><path d="M24 33H48M27 50H45" stroke="#dd7557" stroke-width="5"/><path d="M36 22V43" stroke="#f7e3c6" stroke-width="3"/><path d="M30 61H42" stroke="#6b7887" stroke-width="4"/>',
	"plasmaAmmo": '<path d="M18 27 27 17H45L54 27V49L45 59H27L18 49Z" fill="#263044" stroke="#93a8b9" stroke-width="3"/><circle cx="36" cy="37" r="15" fill="url(#glow)"/><circle cx="36" cy="37" r="9" fill="#bf97f3" stroke="#f4d5ff" stroke-width="2"/><path d="m33 24 7 9-9 10 9 7" fill="none" stroke="#fff0ff" stroke-width="2.5"/><path d="M18 29H25M47 29H54M18 47H25M47 47H54" stroke="#c1b6e3" stroke-width="3"/>',
	"armorPlate": '<path d="m16 23 26-9 18 13-6 29-25 7-17-14Z" fill="#384d60" stroke="#8fa8bc"/><path d="m18 18 25-8 15 13-7 28-23 7-16-14Z" fill="url(#surface)" stroke="#d1e1ea" stroke-width="1.5"/><path d="M24 22 41 17 50 25 45 43 31 48 22 40Z" fill="#576f83"/><path d="m27 27 12-4 5 5-4 10-9 3Z" fill="#a7c9dc"/>',
	"resistanceMembrane": '<path d="m14 23 22-12 22 12v22L36 61 14 45Z" fill="url(#surface)" opacity=".3" stroke="#b3e0f4" stroke-width="2"/><path d="m21 27 15-8 15 8v15L36 53 21 42Z" fill="none" stroke="#8bcfe9" stroke-width="3"/><path d="m28 31 8-5 8 5v8l-8 7-8-7Z" fill="none" stroke="#d8f4ff" stroke-width="2"/><path d="M8 34H20M52 34H64M36 5V17M36 55V67" stroke="#81b5cd" stroke-width="2"/>',
	"nanoArmorRepairer": '<path d="M21 22H49V54H21Z" fill="url(#surface)" stroke="#c3e4d3"/><rect x="27" y="28" width="16" height="19" rx="3" fill="#243c3b"/><path d="M35 32V43M30 37H40" stroke="#b2f4c7" stroke-width="3"/><path d="M49 30H58V18H49M21 46H13V57H24" fill="none" stroke="#79b29f" stroke-width="5" stroke-linejoin="round"/><path d="m53 14 6-5M12 61 6 66M27 15H43M27 60H43" stroke="#bed5cb" stroke-width="3"/>',
	"smallArms": '<path d="M12 28H47L54 24H62V33H46L40 41H31L27 55H20L23 37H12Z" fill="url(#surface)" stroke="#c0c9d4"/><path d="M14 28V20H40V28M45 37V49H38V39" fill="#48576b" stroke="#8495ab" stroke-width="2"/><path d="M12 29H50" stroke="#e9ad78" stroke-width="2"/>',
	"heavyArms": '<path d="M13 44 20 34H53L60 44V55H13Z" fill="url(#surface)" stroke="#cad2ae"/><rect x="22" y="25" width="26" height="14" rx="3" fill="#889373"/><path d="M46 27H65V32H46M30 20H41" stroke="#c4ceb0" stroke-width="4"/><rect x="14" y="49" width="44" height="11" rx="5" fill="#33423c"/><path d="M21 51V58M30 51V58M39 51V58M48 51V58" stroke="#9eae91" stroke-width="3"/>',
	"nanoRepair": '<path d="M26 18H46V27L53 41V57H19V41L26 27Z" fill="url(#surface)" stroke="#b5f4e9"/><rect x="25" y="11" width="22" height="9" rx="2" fill="#789dab"/><path d="M22 42H50V54H22Z" fill="#3daea5"/><path d="M36 29V42M30 35H42" stroke="#ddfff0" stroke-width="3"/>',
	"eq_power_mk1": '<path d="M20 18H52V57H20Z" fill="url(#surface)" stroke="#dbcdb2"/><circle cx="36" cy="37" r="12" fill="#36434c" stroke="#f4c780" stroke-width="2"/><path d="m39 26-9 13h8l-4 11 10-15h-9Z" fill="#f9da93"/><path d="M15 25H20M52 25H57M15 49H20M52 49H57" stroke="#829baa" stroke-width="4"/>',
	"eq_elec_mk1": '<path d="M20 19 53 34 34 51Z" fill="url(#surface)" stroke="#c1e0f2"/><path d="m34 51 4 10H20L26 45M46 27 53 20" fill="none" stroke="#93aabd" stroke-width="4"/><path d="M49 13Q64 17 63 32M52 7Q70 14 69 31" fill="none" stroke="#82caed" stroke-width="2"/>',
	"eq_weapon_mk1": '<path d="M17 43 24 34H49L56 43V56H17Z" fill="url(#surface)" stroke="#ddc3b5"/><path d="M29 35V17H36V35M41 35V13H48V35" stroke="#d0b2a1" stroke-width="6"/><circle cx="36" cy="46" r="7" fill="#4e5a66" stroke="#efb28c" stroke-width="2"/>',
	"eq_defense_mk1": '<path d="M17 18 36 10 55 18V37Q52 53 36 63 20 53 17 37Z" fill="url(#surface)" stroke="#c8d4f1" stroke-width="2"/><path d="M25 24 36 19 47 24V36Q45 46 36 52 27 46 25 36Z" fill="#4d607f" stroke="#b2c6ee"/><path d="M36 23V46M28 35H44" stroke="#9db9ea" stroke-width="3"/>',
	"longbow": '<path d="M36 7 43 27 51 32 55 51 44 47 42 61H30L28 47 17 51 21 32 29 27Z" fill="url(#surface)" stroke="#cbdde7"/><path d="M36 17V50M24 36 30 42M48 36 42 42" stroke="#476076" stroke-width="3"/><path d="M31 59H41" stroke="#78cde7" stroke-width="4"/>',
	"raven": '<path d="M36 10 43 28 62 22 55 45 43 42 40 59H32L29 42 17 45 10 22 29 28Z" fill="url(#surface)" stroke="#c0cce2"/><path d="M36 17V48M18 28 27 36M54 28 45 36" stroke="#404c67" stroke-width="3"/><path d="M33 57H39M15 25V37M57 25V37" stroke="#81b4ec" stroke-width="3"/>',
	"ram": '<path d="M29 10H43L48 25 56 31V52L46 48 42 63H30L26 48 16 52V31L24 25Z" fill="url(#surface)" stroke="#e1ccaf"/><path d="M26 23H46M25 36H47M36 14V51M21 30V43M51 30V43" stroke="#6b615c" stroke-width="4"/><path d="M31 61H41" stroke="#f2b375" stroke-width="4"/>',
	"logistics": '<path d="M29 11H43L47 22 55 24V54L44 50 41 61H31L28 50 17 54V24L25 22Z" fill="url(#surface)" stroke="#c4ded3"/><path d="M20 29H29V46H20ZM43 29H52V46H43Z" fill="#466c68" stroke="#83b1a6"/><path d="M36 16V52M28 21H44" stroke="#4d6c6f" stroke-width="3"/><path d="M31 60H41" stroke="#86d4bb" stroke-width="4"/>',
}

const ROCKS := [
	["13,43 20,23 39,15 58,29 59,47 42,59 23,56", "M20 23 32 37 13 43M32 37 39 15M32 37 42 59M32 37 59 47"],
	["12,39 24,17 45,19 60,38 51,56 28,59", "M24 17 31 39 12 39M31 39 45 19M31 39 51 56M31 39 28 59"],
	["15,47 19,27 32,12 51,22 59,44 42,61", "M32 12 34 38 15 47M34 38 51 22M34 38 42 61M34 38 59 44"],
	["14,46 13,28 33,16 53,22 61,46 43,58 23,57", "M13 28 34 34 53 22M34 34 23 57M34 34 61 46M34 34 33 16"],
	["12,44 20,20 44,13 60,30 57,51 34,60", "M20 20 33 34 44 13M33 34 12 44M33 34 57 51M33 34 34 60"],
]

static var _cache := {}


static func accent(id: String) -> Color:
	if GameData.recipe_faction(id) != "":
		return Color("edac73") if GameData.recipe_faction(id) == "empire" else Color("75cbe6")
	return Color(String(COLORS.get(id, "8eb8c8")))


static func for_good(id: String) -> Texture2D:
	if _cache.has(id):
		return _cache[id]
	var color := String(COLORS.get(id, "8eb8c8"))
	var shape := String(SYMBOLS.get(id, ""))
	var aliases := {"empireReactiveArmor": "armorPlate", "empireSiegeControl": "eq_weapon_mk1", "empireLancer": "longbow",
		"allianceShieldMatrix": "resistanceMembrane", "allianceRepairSwarm": "nanoArmorRepairer", "allianceKite": "raven"}
	if aliases.has(id):
		shape = SYMBOLS[aliases[id]]
		color = accent(id).to_html(false)
	if shape == "" and GameData.is_ore(id):
		var index := GameData.ore_ids().find(id)
		var rock: Array = ROCKS[maxi(index, 0) % ROCKS.size()]
		shape = '<polygon points="%s" fill="url(#surface)" stroke="#%s" stroke-width="1.5"/><path d="%s" fill="none" stroke="#e9f4ff" stroke-width="1.2" opacity=".4"/>' % [rock[0], color, rock[1]]
		if GameData.RARE_IDS.has(id):
			shape += '<path d="m46 15 3 5 6 2-6 2-3 5-2-5-5-2 5-2Z" fill="#f2e7ff" opacity=".9"/>'
	if shape == "":
		shape = '<path d="M16 23 36 13 56 23V49L36 60 16 49ZM16 23 36 34 56 23M36 34V60" fill="url(#surface)" stroke="#bfdce6" stroke-width="2"/>'
	var svg := '<svg xmlns="http://www.w3.org/2000/svg" width="96" height="96" viewBox="0 0 72 72"><defs><linearGradient id="surface" x1="0" y1="0" x2=".8" y2="1"><stop offset="0" stop-color="#%s"/><stop offset="1" stop-color="#273d4d"/></linearGradient><radialGradient id="glow"><stop offset="0" stop-color="#e8c6ff"/><stop offset="1" stop-color="#62519d" stop-opacity=".1"/></radialGradient></defs><ellipse cx="36" cy="61" rx="24" ry="4" fill="#000" opacity=".25"/>%s</svg>' % [color, shape]
	var image := Image.new()
	if image.load_svg_from_string(svg) != OK:
		image = Image.create_empty(96, 96, false, Image.FORMAT_RGBA8)
		image.fill(accent(id))
	var texture := ImageTexture.create_from_image(image)
	_cache[id] = texture
	return texture
