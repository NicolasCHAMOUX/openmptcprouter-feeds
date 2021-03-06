local math  = require "math"
local sys   = require "luci.sys"
local json  = require("luci.json")
local fs    = require("nixio.fs")
local net   = require "luci.model.network".init()
local ucic  = luci.model.uci.cursor()
local ipc = require "luci.ip"
module("luci.controller.openmptcprouter", package.seeall)

function index()
--	entry({"admin", "openmptcprouter"}, firstchild(), _("OpenMPTCProuter"), 19).index = true
--	entry({"admin", "openmptcprouter", "wizard"}, template("openmptcprouter/wizard"), _("Wizard"), 1).leaf = true
--	entry({"admin", "openmptcprouter", "wizard_add"}, post("wizard_add")).leaf = true
	entry({"admin", "system", "openmptcprouter"}, alias("admin", "system", "openmptcprouter", "wizard"), _("OpenMPTCProuter"), 1)
	entry({"admin", "system", "openmptcprouter", "wizard"}, template("openmptcprouter/wizard"), _("Settings Wizard"), 1)
	entry({"admin", "system", "openmptcprouter", "wizard_add"}, post("wizard_add"))
	entry({"admin", "system", "openmptcprouter", "status"}, template("openmptcprouter/wanstatus"), _("Status"), 2).leaf = true
	entry({"admin", "system", "openmptcprouter", "interfaces_status"}, call("interfaces_status")).leaf = true
	entry({"admin", "system", "openmptcprouter", "settings"}, template("openmptcprouter/settings"), _("Advanced Settings"), 3).leaf = true
	entry({"admin", "system", "openmptcprouter", "settings_add"}, post("settings_add"))
	entry({"admin", "system", "openmptcprouter", "update_vps"}, post("update_vps"))
	entry({"admin", "system", "openmptcprouter", "backup"}, template("openmptcprouter/backup"), _("Backup on server"), 3).leaf = true
	entry({"admin", "system", "openmptcprouter", "backupgr"}, post("backupgr"))
	entry({"admin", "system", "openmptcprouter", "debug"}, template("openmptcprouter/debug"), _("Show all settings"), 5).leaf = true
end

function interface_from_device(dev)
	for _, iface in ipairs(net:get_networks()) do
		local ifacen = iface:name()
		local ifacename = ucic:get("network",ifacen,"ifname")
		if ifacename == dev then
			return ifacen
		end
	end
	return ""
end

function wizard_add()
	local gostatus = true
	-- Add new server
	local add_server = luci.http.formvalue("add_server") or ""
	local add_server_name = luci.http.formvalue("add_server_name") or ""
	if add_server ~= "" and add_server_name ~= "" then
		ucic:set("openmptcprouter",add_server_name:gsub("[^%w_]+","_"),"server")
		ucic:set("openmptcprouter",add_server_name:gsub("[^%w_]+","_"),"user","openmptcprouter")
		gostatus = false
	end

	-- Remove existing server
	local delete_server = luci.http.formvaluetable("deleteserver") or ""
	if delete_server ~= "" then
		for serverdel, _ in pairs(delete_server) do
			ucic:foreach("network", "interface", function(s)
				local sectionname = s[".name"]
				ucic:delete("network","server_" .. serverdel .. "_" .. sectionname .. "_route")
			end)
			ucic:delete("network","server_" .. serverdel .. "_default_route")
			ucic:delete("openmptcprouter",serverdel)
			ucic:save("openmptcprouter")
			ucic:commit("openmptcprouter")
			ucic:save("network")
			ucic:commit("network")
			luci.http.redirect(luci.dispatcher.build_url("admin/system/openmptcprouter/wizard"))
			return
		end
	end

	-- Add new interface
	local add_interface = luci.http.formvalue("add_interface") or ""
	local add_interface_ifname = luci.http.formvalue("add_interface_ifname") or ""
	if add_interface ~= "" then
		local i = 1
		local multipath_master = false
		ucic:foreach("network", "interface", function(s)
			local sectionname = s[".name"]
			if sectionname:match("^wan(%d+)$") then
				i = i + 1
			end
			if ucic:get("network",sectionname,"multipath") == "master" then
				multipath_master = true
			end
		end)
		local defif = "eth0"
		if add_interface_ifname == "" then
			local defif1 = ucic:get("network","wan1_dev","ifname") or ""
			if defif1 ~= "" then
				defif = defif1
			end
		else
			defif = add_interface_ifname
		end
		
		local ointf = interface_from_device(defif) or ""
		local wanif = defif
		if ointf ~= "" then
			if ucic:get("network",ointf,"type") == "" then
				ucic:set("network",ointf,"type","macvlan")
			end
			wanif = "wan" .. i
		end
		
		ucic:set("network","wan" .. i,"interface")
		ucic:set("network","wan" .. i,"ifname",defif)
		ucic:set("network","wan" .. i,"proto","static")
		ucic:set("openmptcprouter","wan" .. i,"interface")
		if ointf ~= "" then
			ucic:set("network","wan" .. i,"type","macvlan")
			ucic:set("macvlan","wan" .. i,"macvlan")
			ucic:set("macvlan","wan" .. i,"ifname",defif)
		end
		ucic:set("network","wan" .. i,"ip4table","wan")
		if multipath_master then
			ucic:set("network","wan" .. i,"multipath","on")
			ucic:set("openmptcprouter","wan" .. i,"multipath","on")
		else
			ucic:set("network","wan" .. i,"multipath","master")
			ucic:set("openmptcprouter","wan" .. i,"multipath","master")
		end
		ucic:set("network","wan" .. i,"defaultroute","0")
		ucic:reorder("network","wan" .. i, i + 2)
		ucic:save("macvlan")
		ucic:commit("macvlan")
		ucic:save("network")
		ucic:commit("network")
		ucic:save("openmptcprouter")
		ucic:commit("openmptcprouter")

		ucic:set("qos","wan" .. i,"interface")
		ucic:set("qos","wan" .. i,"classgroup","Default")
		ucic:set("qos","wan" .. i,"enabled","0")
		ucic:set("qos","wan" .. i,"upload","4000")
		ucic:set("qos","wan" .. i,"download","100000")
		ucic:save("qos")
		ucic:commit("qos")

		ucic:set("sqm","wan" .. i,"queue")
		if ointf ~= "" then
			ucic:set("sqm","wan" .. i,"interface","wan" .. i)
		else
			ucic:set("sqm","wan" .. i,"interface",defif)
		end
		ucic:set("sqm","wan" .. i,"qdisc","fq_codel")
		ucic:set("sqm","wan" .. i,"script","simple.qos")
		ucic:set("sqm","wan" .. i,"qdisc_advanced","0")
		ucic:set("sqm","wan" .. i,"linklayer","none")
		ucic:set("sqm","wan" .. i,"enabled","0")
		ucic:set("sqm","wan" .. i,"debug_logging","0")
		ucic:set("sqm","wan" .. i,"verbosity","5")
		ucic:set("sqm","wan" .. i,"download","0")
		ucic:set("sqm","wan" .. i,"upload","0")
		ucic:save("sqm")
		ucic:commit("sqm")
		
		luci.sys.call("uci -q add_list vnstat.@vnstat[-1].interface=" .. wanif)
		luci.sys.call("uci -q commit vnstat")

		-- Dirty way to add new interface to firewall...
		luci.sys.call("uci -q add_list firewall.@zone[1].network=wan" .. i)
		luci.sys.call("uci -q commit firewall")

		luci.sys.call("/etc/init.d/macvlan restart >/dev/null 2>/dev/null")
		gostatus = false
	end

	-- Remove existing interface
	local delete_intf = luci.http.formvaluetable("delete") or ""
	if delete_intf ~= "" then
		for intf, _ in pairs(delete_intf) do
			local defif = ucic:get("network",intf,"ifname")
			ucic:delete("network",intf)
			ucic:delete("network",intf .. "_dev")
			ucic:save("network")
			ucic:commit("network")
			ucic:delete("sqm",intf)
			ucic:save("sqm")
			ucic:commit("sqm")
			ucic:delete("qos",intf)
			ucic:save("qos")
			ucic:commit("qos")
			if defif ~= nil and defif ~= "" then
				luci.sys.call("uci -q del_list vnstat.@vnstat[-1].interface=" .. defif)
			end
			luci.sys.call("uci -q commit vnstat")
			luci.sys.call("uci -q del_list firewall.@zone[1].network=" .. intf)
			luci.sys.call("uci -q commit firewall")
			gostatus = false
		end
	end

	-- Set interfaces settings
	local interfaces = luci.http.formvaluetable("intf")
	for intf, _ in pairs(interfaces) do
		local proto = luci.http.formvalue("cbid.network.%s.proto" % intf) or "static"
		local ipaddr = luci.http.formvalue("cbid.network.%s.ipaddr" % intf) or ""
		local netmask = luci.http.formvalue("cbid.network.%s.netmask" % intf) or ""
		local gateway = luci.http.formvalue("cbid.network.%s.gateway" % intf) or ""
		local sqmenabled = luci.http.formvalue("cbid.sqm.%s.enabled" % intf) or "0"
		if proto ~= "other" then
			ucic:set("network",intf,"proto",proto)
		end
		ucic:set("network",intf,"ipaddr",ipaddr)
		ucic:set("network",intf,"netmask",netmask)
		ucic:set("network",intf,"gateway",gateway)

		ucic:delete("openmptcprouter",intf,"lc")
		ucic:save("openmptcprouter")

		local multipathvpn = luci.http.formvalue("multipathvpn.%s.enabled" % intf) or "0"
		ucic:set("openmptcprouter",intf,"multipathvpn",multipathvpn)
		ucic:save("openmptcprouter")

		local downloadspeed = luci.http.formvalue("cbid.sqm.%s.download" % intf) or "0"
		local uploadspeed = luci.http.formvalue("cbid.sqm.%s.upload" % intf) or "0"

		if not ucic:get("qos",intf) ~= "" then
			ucic:set("qos",intf,"interface")
			ucic:set("qos",intf,"classgroup","Default")
			ucic:set("qos",intf,"enabled","0")
			ucic:set("qos",intf,"upload","4000")
			ucic:set("qos",intf,"download","100000")
		end

		if not ucic:get("sqm",intf) ~= "" then
			local defif = get_device(intf)
			if defif == "" then
				defif = ucic:get("network",intf,"ifname") or ""
			end
			ucic:set("sqm",intf,"queue")
			ucic:set("sqm",intf,"interface",defif)
			ucic:set("sqm",intf,"qdisc","fq_codel")
			ucic:set("sqm",intf,"script","simple.qos")
			ucic:set("sqm",intf,"qdisc_advanced","0")
			ucic:set("sqm",intf,"linklayer","none")
			ucic:set("sqm",intf,"enabled","0")
			ucic:set("sqm",intf,"debug_logging","0")
			ucic:set("sqm",intf,"verbosity","5")
			ucic:set("sqm",intf,"download","0")
			ucic:set("sqm",intf,"upload","0")
		end

		if downloadspeed ~= "0" and uploadspeed ~= "0" then
			ucic:set("network",intf,"downloadspeed",downloadspeed)
			ucic:set("network",intf,"uploadspeed",uploadspeed)
			ucic:set("sqm",intf,"download",math.ceil(downloadspeed*95/100))
			ucic:set("sqm",intf,"upload",math.ceil(uploadspeed*95/100))
			ucic:set("qos",intf,"download",math.ceil(downloadspeed*95/100))
			ucic:set("qos",intf,"upload",math.ceil(uploadspeed*95/100))
		else
			ucic:set("sqm",intf,"download","0")
			ucic:set("sqm",intf,"upload","0")
			ucic:set("sqm",intf,"enabled","0")
			ucic:set("qos",intf,"download","0")
			ucic:set("qos",intf,"upload","0")
			ucic:set("qos",intf,"enabled","0")
		end
		if sqmenabled == "1" then
			ucic:set("sqm",intf,"enabled","1")
			ucic:set("qos",intf,"enabled","1")
		else
			ucic:set("sqm",intf,"enabled","0")
			ucic:set("qos",intf,"enabled","0")
		end
	end
	-- Disable multipath on LAN, VPN and loopback
	ucic:set("network","loopback","multipath","off")
	ucic:set("network","lan","multipath","off")
	ucic:set("network","omr6in4","multipath","off")
	ucic:set("network","omrvpn","multipath","off")

	ucic:save("sqm")
	ucic:commit("sqm")
	ucic:save("qos")
	ucic:commit("qos")
	ucic:save("network")
	ucic:commit("network")

	-- Enable/disable IPv6
	local disableipv6 = luci.http.formvalue("enableipv6") or "1"
	ucic:set("openmptcprouter","settings","disable_ipv6",disableipv6)
	--local ut = require "luci.util"
	--local result = ut.ubus("openmptcprouter", "set_ipv6_state", { disable_ipv6 = disableipv6 })

	-- Get VPN set by default
	local default_vpn = luci.http.formvalue("default_vpn") or "glorytun_tcp"
	local vpn_port = ""
	local vpn_intf = ""
	if default_vpn:match("^glorytun.*") then
		vpn_port = 65001
		vpn_intf = "tun0"
		--ucic:set("network","omrvpn","proto","dhcp")
		ucic:set("network","omrvpn","proto","none")
	elseif default_vpn == "mlvpn" then
		vpn_port = 65201
		vpn_intf = "mlvpn0"
		ucic:set("network","omrvpn","proto","dhcp")
	elseif default_vpn == "ubond" then
		vpn_port = 65201
		vpn_intf = "ubond0"
		ucic:set("network","omrvpn","proto","dhcp")
	elseif default_vpn == "dsvpn" then
		vpn_port = 65011
		vpn_intf = "tun0"
		ucic:set("network","omrvpn","proto","none")
	elseif default_vpn == "openvpn" then
		vpn_port = 65301
		vpn_intf = "tun0"
		ucic:set("network","omrvpn","proto","dhcp")
	end
	if vpn_intf ~= "" then
		ucic:set("network","omrvpn","ifname",vpn_intf)
		ucic:set("sqm","omrvpn","interface",vpn_intf)
		ucic:save("network")
		ucic:commit("network")
		ucic:save("sqm")
		ucic:commit("sqm")
	end

	-- Retrieve all server settings
	local serversnb = 0
	local servers = luci.http.formvaluetable("server")
	for server, _ in pairs(servers) do
		local server_ip = luci.http.formvalue("%s.server_ip" % server) or ""
		local master = luci.http.formvalue("master") or ""

		-- OpenMPTCProuter VPS
		local openmptcprouter_vps_key = luci.http.formvalue("%s.openmptcprouter_vps_key" % server) or ""
		local openmptcprouter_vps_username = luci.http.formvalue("%s.openmptcprouter_vps_username" % server) or ""
		ucic:set("openmptcprouter",server,"server")
		ucic:set("openmptcprouter",server,"username",openmptcprouter_vps_username)
		ucic:set("openmptcprouter",server,"password",openmptcprouter_vps_key)
		if master == server or (master == "" and serversnb == 0) then
			ucic:set("openmptcprouter",server,"get_config","1")
			ucic:set("openmptcprouter",server,"master","1")
			ucic:set("openmptcprouter",server,"backup","0")
		else
			ucic:set("openmptcprouter",server,"get_config","0")
			ucic:set("openmptcprouter",server,"master","0")
			ucic:set("openmptcprouter",server,"backup","1")
		end
		ucic:set("openmptcprouter",server,"ip",server_ip)
		ucic:set("openmptcprouter",server,"port","65500")
		ucic:save("openmptcprouter")
		if server_ip ~= "" then
			serversnb = serversnb + 1
		end
	end

	local ss_servers_nginx = {}
	local ss_servers_ha = {}
	local vpn_servers = {}
	local k = 0
	local ss_ip

	for server, _ in pairs(servers) do
		local master = luci.http.formvalue("master") or ""
		local server_ip = luci.http.formvalue("%s.server_ip" % server) or ""
		-- We have an IP, so set it everywhere
		if server_ip ~= "" then
			-- Check if we have more than one IP, in this case use Nginx HA
			if serversnb > 1 then
				if master == server then
					ss_ip=server_ip
					table.insert(ss_servers_nginx,server_ip .. ":65101 max_fails=2 fail_timeout=20s")
					table.insert(ss_servers_ha,server_ip .. ":65101 check")
					if vpn_port ~= "" then
						table.insert(vpn_servers,server_ip .. ":" .. vpn_port .. " max_fails=2 fail_timeout=20s")
					end
				else
					table.insert(ss_servers_nginx,server_ip .. ":65101 backup")
					table.insert(ss_servers_ha,server_ip .. ":65101 backup")
					if vpn_port ~= "" then
						table.insert(vpn_servers,server_ip .. ":" .. vpn_port .. " backup")
					end
				end
				k = k + 1
				ucic:set("nginx-ha","ShadowSocks","enable","1")
				ucic:set("nginx-ha","VPN","enable","1")
				ucic:set("nginx-ha","ShadowSocks","upstreams",ss_servers_nginx)
				ucic:set("nginx-ha","VPN","upstreams",vpn_servers)
				ucic:set("haproxy-tcp","general","enable","0")
				ucic:set("haproxy-tcp","general","upstreams",ss_servers_ha)
				ucic:set("openmptcprouter","settings","ha","1")
				server_ip = "127.0.0.1"
				--ucic:set("shadowsocks-libev","sss0","server",ss_ip)
			else
				ucic:set("openmptcprouter","settings","ha","0")
				ucic:set("nginx-ha","ShadowSocks","enable","0")
				ucic:set("nginx-ha","VPN","enable","0")
				--ucic:set("shadowsocks-libev","sss0","server",server_ip)
				--ucic:set("openmptcprouter","vps","ip",server_ip)
				--ucic:save("openmptcprouter")
			end
			ucic:set("shadowsocks-libev","sss0","server",server_ip)
			ucic:set("glorytun","vpn","host",server_ip)
			ucic:set("dsvpn","vpn","host",server_ip)
			ucic:set("mlvpn","general","host",server_ip)
			ucic:set("ubond","general","host",server_ip)
			luci.sys.call("uci -q del openvpn.omr.remote")
			luci.sys.call("uci -q add_list openvpn.omr.remote=" .. server_ip)
			ucic:set("qos","serverin","srchost",server_ip)
			ucic:set("qos","serverout","dsthost",server_ip)
		end
	end

	ucic:save("qos")
	ucic:commit("qos")
	ucic:save("nginx-ha")
	ucic:commit("nginx-ha")
	ucic:save("openvpn")
	--ucic:commit("openvpn")
	ucic:save("mlvpn")
	ucic:save("ubond")
	--ucic:commit("mlvpn")
	ucic:save("dsvpn")
	--ucic:commit("dsvpn")
	ucic:save("glorytun")
	--ucic:commit("glorytun")
	ucic:save("shadowsocks-libev")
	--ucic:commit("shadowsocks-libev")


	local encryption = luci.http.formvalue("encryption")
	if encryption == "none" then
		ucic:set("shadowsocks-libev","sss0","method","none")
	elseif encryption == "aes-256-gcm" then
		ucic:set("shadowsocks-libev","sss0","method","aes-256-gcm")
		ucic:set("glorytun","vpn","chacha20","0")
	elseif encryption == "chacha20-ietf-poly1305" then
		ucic:set("shadowsocks-libev","sss0","method","chacha20-ietf-poly1305")
		ucic:set("glorytun","vpn","chacha20","1")
	end

	-- Set ShadowSocks settings
	local shadowsocks_key = luci.http.formvalue("shadowsocks_key")
	local shadowsocks_disable = luci.http.formvalue("disableshadowsocks") or "0"
	if shadowsocks_key ~= "" then
		ucic:set("shadowsocks-libev","sss0","key",shadowsocks_key)
		--ucic:set("shadowsocks-libev","sss0","method","chacha20-ietf-poly1305")
		--ucic:set("shadowsocks-libev","sss0","server_port","65101")
		ucic:set("shadowsocks-libev","sss0","disabled",shadowsocks_disable)
		ucic:save("shadowsocks-libev")
		ucic:commit("shadowsocks-libev")
		if shadowsocks_disable == "1" then
			luci.sys.call("/etc/init.d/shadowsocks rules_down >/dev/null 2>/dev/null")
		end
	else
		ucic:set("shadowsocks-libev","sss0","key","")
		ucic:set("shadowsocks-libev","sss0","disabled",shadowsocks_disable)
		ucic:save("shadowsocks-libev")
		ucic:commit("shadowsocks-libev")
		luci.sys.call("/etc/init.d/shadowsocks rules_down >/dev/null 2>/dev/null")
	end

	-- Set Glorytun settings
	if default_vpn:match("^glorytun.*") then
		ucic:set("glorytun","vpn","enable",1)
	else
		ucic:set("glorytun","vpn","enable",0)
	end

	local glorytun_key = luci.http.formvalue("glorytun_key")
	if glorytun_key ~= "" then
		ucic:set("glorytun","vpn","port","65001")
		ucic:set("glorytun","vpn","key",glorytun_key)
		ucic:set("glorytun","vpn","mptcp",1)
		if default_vpn == "glorytun_udp" then
			ucic:set("glorytun","vpn","proto","udp")
			ucic:set("glorytun","vpn","localip","10.255.254.2")
			ucic:set("glorytun","vpn","remoteip","10.255.254.1")
			ucic:set("network","omr6in4","ipaddr","10.255.254.2")
			ucic:set("network","omr6in4","peeraddr","10.255.254.1")
		else
			ucic:set("glorytun","vpn","proto","tcp")
			ucic:set("glorytun","vpn","localip","10.255.255.2")
			ucic:set("glorytun","vpn","remoteip","10.255.255.1")
			ucic:set("network","omr6in4","ipaddr","10.255.255.2")
			ucic:set("network","omr6in4","peeraddr","10.255.255.1")
		end
		ucic:set("network","omrvpn","proto","none")
	else
		ucic:set("glorytun","vpn","key","")
		--ucic:set("glorytun","vpn","enable",0)
		ucic:set("glorytun","vpn","proto","tcp")
	end
	ucic:save("glorytun")
	ucic:commit("glorytun")

	-- Set A Dead Simple VPN settings
	if default_vpn == "dsvpn" then
		ucic:set("dsvpn","vpn","enable",1)
	else
		ucic:set("dsvpn","vpn","enable",0)
	end

	local dsvpn_key = luci.http.formvalue("dsvpn_key")
	if dsvpn_key ~= "" then
		ucic:set("dsvpn","vpn","port","65011")
		ucic:set("dsvpn","vpn","key",dsvpn_key)
		ucic:set("dsvpn","vpn","localip","10.255.251.2")
		ucic:set("dsvpn","vpn","remoteip","10.255.251.1")
		ucic:set("network","omr6in4","ipaddr","10.255.251.2")
		ucic:set("network","omr6in4","peeraddr","10.255.251.1")
		ucic:set("network","omrvpn","proto","none")
	else
		ucic:set("dsvpn","vpn","key","")
		--ucic:set("dsvpn","vpn","enable",0)
	end
	ucic:save("dsvpn")
	ucic:commit("dsvpn")

	-- Set MLVPN settings
	if default_vpn == "mlvpn" then
		ucic:set("mlvpn","general","enable",1)
		ucic:set("network","omrvpn","proto","dhcp")
	else
		ucic:set("mlvpn","general","enable",0)
	end

	local mlvpn_password = luci.http.formvalue("mlvpn_password")
	if mlvpn_password ~= "" then
		ucic:set("mlvpn","general","password",mlvpn_password)
		ucic:set("mlvpn","general","firstport","65201")
		ucic:set("mlvpn","general","interface_name","mlvpn0")
	else
		--ucic:set("mlvpn","general","enable",0)
		ucic:set("mlvpn","general","password","")
	end
	ucic:save("mlvpn")
	ucic:commit("mlvpn")

	-- Set UBOND settings
	if default_vpn == "ubond" then
		ucic:set("ubond","general","enable",1)
		ucic:set("network","omrvpn","proto","dhcp")
	else
		ucic:set("ubond","general","enable",0)
	end

	local ubond_password = luci.http.formvalue("ubond_password")
	if ubond_password ~= "" then
		ucic:set("ubond","general","password",ubond_password)
		ucic:set("ubond","general","firstport","65201")
		ucic:set("ubond","general","interface_name","ubond0")
	else
		--ucic:set("ubond","general","enable",0)
		ucic:set("ubond","general","password","")
	end
	ucic:save("ubond")
	ucic:commit("ubond")

	if default_vpn == "openvpn" then
		ucic:set("openvpn","omr","enabled",1)
		ucic:set("network","omrvpn","proto","none")
	else
		ucic:set("openvpn","omr","enabled",0)
	end
	ucic:save("openvpn")
	ucic:commit("openvpn")
	ucic:save("network")
	ucic:commit("network")

	-- OpenMPTCProuter VPS
	--local openmptcprouter_vps_key = luci.http.formvalue("openmptcprouter_vps_key") or ""
	--ucic:set("openmptcprouter","vps","username","openmptcprouter")
	--ucic:set("openmptcprouter","vps","password",openmptcprouter_vps_key)
	--ucic:set("openmptcprouter","vps","get_config","1")
	local shadowsocks_disable = luci.http.formvalue("disableshadowsocks") or "0"
	ucic:set("openmptcprouter","settings","shadowsocks_disable",shadowsocks_disable)
	ucic:set("openmptcprouter","settings","vpn",default_vpn)
	ucic:delete("openmptcprouter","settings","master_lcintf")
	ucic:save("openmptcprouter")
	ucic:commit("openmptcprouter")

	-- Restart all
	if gostatus == true then
		luci.sys.call("(env -i /bin/ubus call network reload) >/dev/null 2>/dev/null")
		luci.sys.call("/etc/init.d/mptcp restart >/dev/null 2>/dev/null")
		if openmptcprouter_vps_key ~= "" then
			luci.sys.call("/etc/init.d/openmptcprouter-vps restart >/dev/null 2>/dev/null")
			os.execute("sleep 2")
		end
		luci.sys.call("/etc/init.d/shadowsocks-libev restart >/dev/null 2>/dev/null")
		luci.sys.call("/etc/init.d/glorytun restart >/dev/null 2>/dev/null")
		luci.sys.call("/etc/init.d/glorytun-udp restart >/dev/null 2>/dev/null")
		luci.sys.call("/etc/init.d/mlvpn restart >/dev/null 2>/dev/null")
		luci.sys.call("/etc/init.d/ubond restart >/dev/null 2>/dev/null")
		luci.sys.call("/etc/init.d/openvpn restart >/dev/null 2>/dev/null")
		luci.sys.call("/etc/init.d/dsvpn restart >/dev/null 2>/dev/null")
		luci.sys.call("/etc/init.d/omr-tracker restart >/dev/null 2>/dev/null")
		luci.sys.call("/etc/init.d/omr-6in4 restart >/dev/null 2>/dev/null")
		luci.sys.call("/etc/init.d/mptcpovervpn restart >/dev/null 2>/dev/null")
		luci.sys.call("/etc/init.d/vnstat restart >/dev/null 2>/dev/null")
		luci.http.redirect(luci.dispatcher.build_url("admin/system/openmptcprouter/status"))
	else
		luci.http.redirect(luci.dispatcher.build_url("admin/system/openmptcprouter/wizard"))
	end
	return
end

function settings_add()
	-- Redirects all ports from VPS to OpenMPTCProuter
	local servers = luci.http.formvaluetable("server")
	local redirect_ports = luci.http.formvaluetable("redirect_ports")
	for server, _ in pairs(servers) do
		local redirectports = luci.http.formvalue("redirect_ports.%s" % server) or "0"
		ucic:set("openmptcprouter",server,"redirect_ports",redirectports)
		local nofwredirect = luci.http.formvalue("nofwredirect.%s" % server) or "0"
		ucic:set("openmptcprouter",server,"nofwredirect",nofwredirect)
	end

	-- Set tcp_keepalive_time
	local tcp_keepalive_time = luci.http.formvalue("tcp_keepalive_time")
	luci.sys.exec("sysctl -w net.ipv4.tcp_keepalive_time=%s" % tcp_keepalive_time)
	luci.sys.exec("sed -i 's:^net.ipv4.tcp_keepalive_time=[0-9]*:net.ipv4.tcp_keepalive_time=%s:' /etc/sysctl.d/zzz_openmptcprouter.conf" % tcp_keepalive_time)

	-- Set tcp_fin_timeout
	local tcp_fin_timeout = luci.http.formvalue("tcp_fin_timeout")
	luci.sys.exec("sysctl -w net.ipv4.tcp_fin_timeout=%s" % tcp_fin_timeout)
	luci.sys.exec("sed -i 's:^net.ipv4.tcp_fin_timeout=[0-9]*:net.ipv4.tcp_fin_timeout=%s:' /etc/sysctl.d/zzz_openmptcprouter.conf" % tcp_fin_timeout)

	-- Set tcp_syn_retries
	local tcp_syn_retries = luci.http.formvalue("tcp_syn_retries")
	luci.sys.exec("sysctl -w net.ipv4.tcp_syn_retries=%s" % tcp_syn_retries)
	luci.sys.exec("sed -i 's:^net.ipv4.tcp_syn_retries=[0-9]*:net.ipv4.tcp_syn_retries=%s:' /etc/sysctl.d/zzz_openmptcprouter.conf" % tcp_syn_retries)
	
	-- Set tcp_fastopen
	local tcp_fastopen = luci.http.formvalue("tcp_fastopen")
	local disablefastopen = luci.http.formvalue("disablefastopen") or "0"
	if disablefastopen == "1" then
		tcp_fastopen = "0"
	elseif tcp_fastopen == "0" and disablefastopen == "0" then
		tcp_fastopen = "3"
	end
	luci.sys.exec("sysctl -w net.ipv4.tcp_fastopen=%s" % tcp_fastopen)
	luci.sys.exec("sed -i 's:^net.ipv4.tcp_fastopen=[0-3]*:net.ipv4.tcp_fastopen=%s:' /etc/sysctl.d/zzz_openmptcprouter.conf" % tcp_fastopen)
	ucic:set("openmptcprouter", "settings","disable_fastopen", disablefastopen)
	
	-- Disable IPv6
	local disable_ipv6 = luci.http.formvalue("enableipv6") or "1"
	local dump = require("luci.util").ubus("openmptcprouter", "disableipv6", { disable_ipv6 = tonumber(disable_ipv6)})

	-- Enable/disable external check
	local externalcheck = luci.http.formvalue("externalcheck") or "1"
	ucic:set("openmptcprouter","settings","external_check",externalcheck)

	-- Enable/disable external check
	local savevnstat = luci.http.formvalue("savevnstat") or "0"
	luci.sys.exec("uci -q set vnstat.@vnstat[0].backup=%s" % savevnstat)
	ucic:commit("vnstat")

	-- Enable/disable gateway ping
	local disablegwping = luci.http.formvalue("disablegwping") or "0"
	ucic:set("openmptcprouter","settings","disablegwping",disablegwping)

	-- Enable/disable server ping
	local disableserverping = luci.http.formvalue("disableserverping") or "0"
	ucic:set("openmptcprouter","settings","disableserverping",disableserverping)

	-- Enable/disable fast open
	local disablefastopen = luci.http.formvalue("disablefastopen") or "0"
	if disablefastopen == "0" then
		fastopen = "1"
	else
		fastopen = "0"
	end
	ucic:foreach("shadowsocks-libev", "ss_redir", function (section)
		ucic:set("shadowsocks-libev",section[".name"],"fast_open",fastopen)
	end)
	ucic:foreach("shadowsocks-libev", "ss_local", function (section)
		ucic:set("shadowsocks-libev",section[".name"],"fast_open",fastopen)
	end)


	-- Enable/disable obfs
	local obfs = luci.http.formvalue("obfs") or "0"
	local obfs_plugin = luci.http.formvalue("obfs_plugin") or "v2ray"
	local obfs_type = luci.http.formvalue("obfs_type") or "http"
	ucic:foreach("shadowsocks-libev", "server", function (section)
		ucic:set("shadowsocks-libev",section[".name"],"obfs",obfs)
		ucic:set("shadowsocks-libev",section[".name"],"obfs_plugin",obfs_plugin)
		ucic:set("shadowsocks-libev",section[".name"],"obfs_type",obfs_type)
	end)
	ucic:save("shadowsocks-libev")
	ucic:commit("shadowsocks-libev")

	-- Set master to dynamic or static
	local master_type = luci.http.formvalue("master_type") or "static"
	ucic:set("openmptcprouter","settings","master",master_type)

	-- Set CPU scaling minimum frequency
	local scaling_min_freq = luci.http.formvalue("scaling_min_freq") or ""
	if scaling_min_freq ~= "" then
		ucic:set("openmptcprouter","settings","scaling_min_freq",scaling_min_freq)
	end

	-- Set CPU scaling maximum frequency
	local scaling_max_freq = luci.http.formvalue("scaling_max_freq") or ""
	if scaling_max_freq ~= "" then
		ucic:set("openmptcprouter","settings","scaling_max_freq",scaling_max_freq)
	end

	-- Set CPU governor
	local scaling_governor = luci.http.formvalue("scaling_governor") or ""
	if scaling_governor ~= "" then
		ucic:set("openmptcprouter","settings","scaling_governor",scaling_governor)
	end

	ucic:save("openmptcprouter")
	ucic:commit("openmptcprouter")

	-- Apply all settings
	luci.sys.call("/etc/init.d/openmptcprouter restart >/dev/null 2>/dev/null")

	-- Done, redirect
	luci.http.redirect(luci.dispatcher.build_url("admin/system/openmptcprouter/settings"))
	return
end

function update_vps()
	-- Update VPS
	local update_vps = luci.http.formvalue("flash") or ""
	if update_vps ~= "" then
		local ut = require "luci.util"
		local result = ut.ubus("openmptcprouter", "update_vps", {})
	end
	return
end

function backupgr()
	local get_backup = luci.http.formvalue("restore") or ""
	if get_backup ~= "" then
		luci.sys.call("/etc/init.d/openmptcprouter-vps backup_get >/dev/null 2>/dev/null")
	end
	local send_backup = luci.http.formvalue("save") or ""
	if send_backup ~= "" then
		luci.sys.call("/etc/init.d/openmptcprouter-vps backup_send >/dev/null 2>/dev/null")
	end
	luci.http.redirect(luci.dispatcher.build_url("admin/system/openmptcprouter/backup"))
	return
end

function get_device(interface)
	local dump = require("luci.util").ubus("network.interface.%s" % interface, "status", {})
	if dump ~= nil then
		return dump['l3_device']
	else
		return ""
	end
end

-- This function come from modules/luci-bbase/luasrc/tools/status.lua from old OpenWrt
-- Copyright 2011 Jo-Philipp Wich <jow@openwrt.org>
-- Licensed to the public under the Apache License 2.0.
local function dhcp_leases_common(family)
	local rv = { }
	local nfs = require "nixio.fs"
	local sys = require "luci.sys"
	local leasefile = "/tmp/dhcp.leases"

	ucic:foreach("dhcp", "dnsmasq",
	    function(s)
		    if s.leasefile and nfs.access(s.leasefile) then
			    leasefile = s.leasefile
			    return false
		    end
	    end)

	local fd = io.open(leasefile, "r")
	if fd then
		while true do
			local ln = fd:read("*l")
			if not ln then
				break
			else
				local ts, mac, ip, name, duid = ln:match("^(%d+) (%S+) (%S+) (%S+) (%S+)")
				local expire = tonumber(ts) or 0
				if ts and mac and ip and name and duid then
					if family == 4 and not ip:match(":") then
						rv[#rv+1] = {
						    expires  = (expire ~= 0) and os.difftime(expire, os.time()),
						    macaddr  = ipc.checkmac(mac) or "00:00:00:00:00:00",
						    ipaddr   = ip,
						    hostname = (name ~= "*") and name
						}
					elseif family == 6 and ip:match(":") then
						rv[#rv+1] = {
						    expires  = (expire ~= 0) and os.difftime(expire, os.time()),
						    ip6addr  = ip,
						    duid     = (duid ~= "*") and duid,
						    hostname = (name ~= "*") and name
						}
					end
				end
			end
		end
		fd:close()
	end

	local lease6file = "/tmp/hosts/odhcpd"
	ucic:foreach("dhcp", "odhcpd",
	    function(t)
		    if t.leasefile and nfs.access(t.leasefile) then
			    lease6file = t.leasefile
			    return false
		    end
	end)
	local fd = io.open(lease6file, "r")
	if fd then
		while true do
			local ln = fd:read("*l")
			if not ln then
				break
			else
				local iface, duid, iaid, name, ts, id, length, ip = ln:match("^# (%S+) (%S+) (%S+) (%S+) (-?%d+) (%S+) (%S+) (.*)")
				local expire = tonumber(ts) or 0
				if ip and iaid ~= "ipv4" and family == 6 then
					rv[#rv+1] = {
					    expires  = (expire >= 0) and os.difftime(expire, os.time()),
					    duid     = duid,
					    ip6addr  = ip,
					    hostname = (name ~= "-") and name
					}
				elseif ip and iaid == "ipv4" and family == 4 then
					rv[#rv+1] = {
					    expires  = (expire >= 0) and os.difftime(expire, os.time()),
					    macaddr  = sys.net.duid_to_mac(duid) or "00:00:00:00:00:00",
					    ipaddr   = ip,
					    hostname = (name ~= "-") and name
					}
				end
			end
		end
		fd:close()
	end

	if family == 6 then
		local _, lease
		local hosts = sys.net.host_hints()
		for _, lease in ipairs(rv) do
			local mac = sys.net.duid_to_mac(lease.duid)
			local host = mac and hosts[mac]
			if host then
				if not lease.name then
					lease.host_hint = host.name or host.ipv4 or host.ipv6
				elseif host.name and lease.hostname ~= host.name then
					lease.host_hint = host.name
				end
			end
		end
	end

	return rv
end

function interfaces_status()
	local ut = require "luci.util"
	local mArray = ut.ubus("openmptcprouter", "status", {}) or {_=0}

	if mArray ~= nil and mArray.openmptcprouter ~= nil then
		mArray.openmptcprouter["remote_addr"] = luci.http.getenv("REMOTE_ADDR") or ""
		mArray.openmptcprouter["remote_from_lease"] = false
		local leases=dhcp_leases_common(4)
		for _, value in pairs(leases) do
			if value["ipaddr"] == mArray.openmptcprouter["remote_addr"] then
				mArray.openmptcprouter["remote_from_lease"] = true
				mArray.openmptcprouter["remote_hostname"] = value["hostname"]
			end
		end
	end

	luci.http.prepare_content("application/json")
	luci.http.write_json(mArray)
end
