extends DotGameNetLink

## This game's link: the shared skeleton in [DotGameNetLink], plus the names that are its own.

const DrNetLink := preload("dr_net_link.gd")

const CHANNEL := "dr.link"

## The node name both ends must use. It is the routing, so it is a constant.
const NODE_NAME := &"Deathrun"


func _init() -> void:
	channel = CHANNEL


static func attached_to(parent: Node, p_bridge: Node, server: bool) -> DrNetLink:
	var link := DrNetLink.new()
	link.bridge = p_bridge
	link.is_server = server
	return link
