@tool
class_name GSCloudWorkshopConfig
extends GSConfig

## Workshop sync client settings, layered like every [GSConfig]: defaults, JSON file,
## [code]GS_CLOUD_WORKSHOP_*[/code] environment, [code]--cloud-workshop-*[/code] arguments.
## The subscription list is never read from here.

## Off: [method GSCloudWorkshop.sync] succeeds with nothing mounted, and the panel says the
## Workshop is off on this build.
@export var workshop_enabled: bool = true

## The site origin. The shell passes its gs-auth backbone url; nothing a page supplies belongs here.
@export var workshop_backbone_url: String = ""

## [code]never[/code], [code]approved[/code] or [code]any[/code]: whether a pack that runs code
## is mounted. [code]approved[/code] needs the site's reviewers to have approved that version;
## [code]any[/code] (site-signed, unreviewed) is for a developer testing their own pack.
@export var workshop_script_packs: String = "approved"

## Narrows the [code]key_id[/code]s a subscription manifest may be signed with, out of the client's
## [member GSCloudConfig.trusted_keys]. Empty takes the whole keyring; an id it lacks trusts nothing.
## Name ids to keep a server-content key out of a stranger's subscriptions.
@export var workshop_key_ids: PackedStringArray = PackedStringArray()

## [code]ask[/code], [code]allow[/code] or [code]never[/code]: what to do on a metered connection.
## A device override (see [GSCloudWorkshopDevice]) wins over this.
@export var workshop_metered: String = "ask"

## Download size above which the player is asked on [code]ask[/code], metered or not.
@export var workshop_ask_over_bytes: int = 52428800

## The list request's timeout; past it the cached list is used.
@export_range(1.0, 120.0, 0.5) var workshop_timeout_sec: float = 10.0

## The most packs one launch will mount. 0 is no limit.
@export var workshop_max_packs: int = 200

## The most subscribed addon packs one launch will lay over the build (see docs/workshop.md, addon
## packs). 0 is no limit. They also count toward [member workshop_max_packs].
@export var workshop_max_addon_packs: int = 0

## Whether the game's suggested packs (its map packs) are mounted: [code]all[/code], [code]none[/code]
## or a comma list of groups. See [GSCloudSuggested] for the full precedence.
@export var workshop_suggested: String = "all"


func env_prefix() -> String:
	return "GS_CLOUD_"


func cli_prefix() -> String:
	return "--cloud-"


func validate() -> GSResult:
	if not ["never", "approved", "any"].has(workshop_script_packs):
		return GSResult.fail(
			GSError.CODE_INVALID, "workshop_script_packs must be never, approved or any.",
			workshop_script_packs
		)
	if not ["ask", "allow", "never"].has(workshop_metered):
		return GSResult.fail(
			GSError.CODE_INVALID, "workshop_metered must be ask, allow or never.", workshop_metered
		)
	if not GSCloudSuggested.valid_mode(workshop_suggested):
		return GSResult.fail(
			GSError.CODE_INVALID, "workshop_suggested must be all, none or a comma list of groups.",
			workshop_suggested
		)
	if workshop_max_packs < 0:
		return GSResult.fail(GSError.CODE_INVALID, "workshop_max_packs must not be negative.")
	if workshop_max_addon_packs < 0:
		return GSResult.fail(GSError.CODE_INVALID, "workshop_max_addon_packs must not be negative.")
	return GSResult.success(null)
