@tool
extends EditorPlugin

## Editor entry point for GameSpice Cloud.
##
## Registers inspector types and nothing else. Like GameSpice Core, GameSpice Cloud has no
## autoloads: a project may run several [GSCloudClient]s (one per content
## channel, or one per server it is talking to) and a singleton would make that
## impossible.

const _ICON := "res://addons/dot_cloud/icon_placeholder.svg"


func _enter_tree() -> void:
	var icon: Texture2D = null
	if ResourceLoader.exists(_ICON):
		icon = load(_ICON) as Texture2D

	add_custom_type(
		"GSCloudClient",
		"Node",
		load("res://addons/dot_cloud/client/dot_cloud_client.gd"),
		icon
	)
	add_custom_type(
		"GSCloudDownloader",
		"Node",
		load("res://addons/dot_cloud/transfer/dot_cloud_downloader.gd"),
		icon
	)


func _exit_tree() -> void:
	remove_custom_type("GSCloudDownloader")
	remove_custom_type("GSCloudClient")
