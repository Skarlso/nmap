---
-- A library providing functions for collecting SSL certificates and storing
-- them in the host-based registry.
--
-- The library is largely based on code (copy-pasted) from David Fifields
-- ssl-cert script in an effort to allow certs to be cached and shared among
-- other scripts.
--
-- STARTTLS functions are included for several protocols:
--
-- * FTP
-- * IMAP
-- * LDAP
-- * NNTP
-- * MySQL
-- * POP3
-- * PostgreSQL
-- * SMTP
-- * TDS (MS SQL Server)
-- * VNC (TLS and VeNCrypt auth types)
-- * XMPP
--
-- @author Patrik Karlsson <patrik@cqure.net>

local asn1 = require "asn1"
local comm = require "comm"
local ftp = require "ftp"
local ldap = require "ldap"
local match = require "match"
local mssql = require "mssql"
local mysql = require "mysql"
local nmap = require "nmap"
local smtp = require "smtp"
local stdnse = require "stdnse"
local string = require "string"
local table = require "table"
local tableaux = require "tableaux"
local tls = require "tls"
local vnc = require "vnc"
local xmpp = require "xmpp"
local have_openssl, openssl = pcall(require, "openssl")
_ENV = stdnse.module("sslcert", stdnse.seeall)

if have_openssl then
  --- Parse an X.509 certificate from DER-encoded string
  --
  -- This uses OpenSSL's X.509 parsing routines, so if OpenSSL support is not
  -- included, only the <code>pem</code> key of the returned table will be
  -- present.
  --@name parse_ssl_certificate
  --@class function
  --@param der DER-encoded certificate
  --@return table containing decoded certificate or nil on failure
  --@return error string if parsing failed
  --@see nmap.get_ssl_certificate
  _ENV.parse_ssl_certificate = nmap.socket.parse_ssl_certificate
else
  local base64 = require "base64"
  _ENV.parse_ssl_certificate = function(der)
    return {
      pem = ("-----BEGIN CERTIFICATE-----\n%s\n-----END CERTIFICATE-----\n"):format(
        base64.enc(der):gsub("(" .. ("."):rep(64) .. ")", "%1\n"):gsub("\n$", "")
        )
    }
  end
end

-- Mark whether this port supports STARTTLS, to save connection attempts later.
-- If it ever succeeds, it can't be marked as failing later, but if it fails
-- the first time, we won't try again.
local function starttls_supported(host, port, state)
  host.registry.starttls = host.registry.starttls or {}
  local reg = host.registry.starttls
  local mutex = nmap.mutex(reg)
  local key = ("%d/%s"):format(port.number, port.protocol)
  if reg[key] ~= nil then
    return reg[key]
  end
  -- try releasing mutex, ignore error if we don't hold it.
  pcall(mutex, "done")
  reg[key] = state
  host.registry.starttls_failed = reg
end

-- Check whether we've tried and failed to STARTTLS already
local function check_starttls_failed (host, port)
  host.registry.starttls = host.registry.starttls or {}
  local reg = host.registry.starttls
  local key = ("%d/%s"):format(port.number, port.protocol)
  local mutex = nmap.mutex(reg)
  mutex "lock"
  if reg[key] ~= nil then
    -- somebody already did the hard work.
    mutex "done"
    return not reg[key]
  end
  -- no idea. Keep it locked until we know.
end

-- Simple reconnect_ssl wrapper for most common case
local function tls_reconnect (func)
  return function (host, port)
    local err
    local status, s = StartTLS[func](host, port)
    if status then
      status,err = s:reconnect_ssl()
      if not status then
        stdnse.debug1("Could not establish SSL session after STARTTLS command.")
        s:close()
        return false, "Failed to connect to server"
      else
        return true, s
      end
    end
    return false, string.format("Failed to connect to server: %s", s or "unknown error")
  end
end

-- Class for sockets which wrap sends and receives in some sort of tunnel
-- Overload the wrap_close, wrap_send, and wrap_receive functions to use it.
-- The socket won't be able to reconnect_ssl, though, since Nsock has
-- no idea about the wrapper. Still useful for ssl-* scripts.
WrappedSocket =
{
  new = function(self, socket, o)
    assert(socket, "socket must be connected socket!")
    o = o or {}
    o.socket = socket
    setmetatable(o, self)
    self.__index = function(instance, key)
      return rawget(self, key) or instance.socket[key]
    end
    return o
  end,

  close = function(self)
    return self:wrap_close()
  end,

  receive = function(self)
    return self:wrap_receive()
  end,

  send = function(self, data)
    return self:wrap_send(data)
  end,

  set_timeout = function(self, timeout)
    return self.socket:set_timeout(timeout)
  end,

  receive_buf = function(self, delimiter, keeppattern)
    self.buffer = self.buffer or ""
    local delim_func
    if type(delimiter) == "function" then
      delim_func = delimiter
    else
      delim_func = function(buf)
        return string.find(buf, delimiter)
      end
    end
    local start, finish = delim_func(self.buffer)
    if start then
      local rval
      if keeppattern then
        rval = string.sub(self.buffer, 1, finish)
      else
        rval = string.sub(self.buffer, 1, start - 1)
      end
      self.buffer = string.sub(self.buffer, finish + 1)
      return true, rval
    else
      local status, data = self:receive()
      if not status then
        return status, data
      end
      self.buffer = self.buffer .. data
      -- tail recursion
      return self:receive_buf(delimiter, keeppattern)
    end
  end,

  receive_bytes = function(self, n)
    local x = 0
    local read = {}
    while x < n do
      local status, data = self:receive()
      if not status then
        return status, data
      end
      read[#read+1] = data
      x = x + #data
    end
    return true, table.concat(read)
  end,

  receive_lines = function(self, n)
    local x = 0
    local read = {}
    local function incr()
      x = x + 1
    end
    while x < n do
      local status, data = self:receive()
      if not status then
        return status, data
      end
      read[#read+1] = data
      string.gsub(data, "\n", incr)
    end
    return true, table.concat(read)
  end,

  }


StartTLS = {

  ftp_prepare_tls_without_reconnect = function(host, port)
    -- Attempt to negotiate TLS over FTP for services that support it
    -- Works for FTP (21)

    -- Open a standard TCP socket
    local s, code, result, buf = ftp.connect(host, port)
    if not s then
      return false, string.format("Failed to connect to FTP server: %s", code)
    end
    if code ~= 220 then
      return false, string.format("FTP protocol error: %s", code or result)
    end

    -- Send AUTH TLS command, ask the service to start encryption
    local status, err = ftp.starttls(s, buf)
    if not status then
      starttls_supported(host, port, false)
      ftp.close(s)
      return false, string.format("FTP AUTH TLS error: %s", err)
    end
    -- Should have a solid TLS over FTP session now...
    starttls_supported(host, port, true)
    return true, s
  end,

  ftp_prepare_tls = tls_reconnect("ftp_prepare_tls_without_reconnect"),

  imap_prepare_tls_without_reconnect = function(host, port)
    -- Attempt to negotiate TLS over IMAP for services that support it
    -- Works for IMAP (143)

    -- Open a standard TCP socket
    local s, err, result = comm.opencon(host, port, "", {lines=1, recv_before=true})
    if not s then
      return false, string.format("Failed to connect to IMAP server: %s", err)
    end

    if not string.match(result, "^%* OK") then
      return false, "IMAP protocol mismatch"
    end

    -- Check for STARTTLS support.
    local status = s:send("A001 CAPABILITY\r\n")
    status, result = s:receive_lines(1)

    if not (string.match(result, "STARTTLS")) then
      starttls_supported(host, port, false)
      stdnse.debug1("Server doesn't support STARTTLS")
      return false, "Failed to connect to IMAP server"
    end

    -- Send the STARTTLS message
    status = s:send("A002 STARTTLS\r\n")
    status, result = s:receive_lines(1)

    if not (string.match(result, "^A002 OK")) then
      starttls_supported(host, port, false)
      stdnse.debug1(string.format("Error: %s", result))
      return false, "Failed to connect to IMAP server"
    end

    -- Should have a solid TLS over IMAP session now...
    starttls_supported(host, port, true)
    return true, s
  end,

  imap_prepare_tls = tls_reconnect("imap_prepare_tls_without_reconnect"),

  ldap_prepare_tls_without_reconnect = function(host, port)
    local s = nmap.new_socket()
    -- Attempt to negotiate TLS over LDAP for services that support it
    -- Works for LDAP (389)

    -- Open a standard TCP socket
    local status, error = s:connect(host, port, "tcp")
    if not status then
      return false, "Failed to connect to LDAP server"
    end

    -- Create an LDAP extendedRequest and specify the OID for the
    -- STARTTLS operation (see http://www.ietf.org/rfc/rfc2830.txt)
    local oid = "1.3.6.1.4.1.1466.20037"

    -- 0x80  = 10000001  =  10        0                 00000
    -- hex     binary       Context   Primitive value   Field: requestName  Value: 0
    local encodedOID = string.pack('Bs1', 0x80, oid)

    local ldapRequest, ldapRequestId
    local ExtendedRequest = 23
    local ExtendedResponse = 24
    ldapRequest = ldap.encodeLDAPOp(ExtendedRequest, true, encodedOID)
    ldapRequestId = ldap.encode(1)

    -- Send the STARTTLS request
    local encoder = asn1.ASN1Encoder:new()
    local data = encoder:encodeSeq(ldapRequestId .. ldapRequest)
    status = s:send(data)
    if not status then
      return false, "STARTTLS failed"
    end

    -- Decode the response
    local response
    status, response = s:receive()
    if not status then
      return false, "STARTTLS failed"
    end

    local decoder = asn1.ASN1Decoder:new()
    local len, pos, messageId, ldapOp, tmp = ""
    len, pos = decoder.decodeLength(response, 2)
    messageId, pos = ldap.decode(response, pos)
    tmp, pos = string.unpack("B", response, pos)
    ldapOp = asn1.intToBER(tmp)

    if ldapOp.number ~= ExtendedResponse then
      starttls_supported(host, port, false)
      stdnse.debug1(string.format(
        "STARTTLS failed (got wrong op number: %d)", ldapOp.number))
      return false, "STARTTLS failed"
    end

    local resultCode
    len, pos = decoder.decodeLength(response, pos)
    resultCode, pos = ldap.decode(response, pos)

    if resultCode ~= 0 then
      starttls_supported(host, port, false)
      stdnse.debug1(string.format(
        "STARTTLS failed (LDAP error code is: %s)", tonumber(resultCode) or "not a number"))
      return false, "STARTTLS failed"
    end

    -- Should have a solid TLS over LDAP session now...
    starttls_supported(host, port, true)
    return true,s
  end,

  ldap_prepare_tls = tls_reconnect("ldap_prepare_tls_without_reconnect"),

  lmtp_prepare_tls_without_reconnect = function(host, port)
    -- Open a standard TCP socket
    local s, result = smtp.connect(host, port, {lines=1, recv_before=1, ssl=false})
    if not s then
      return false, string.format("Failed to connect to LMTP server: %s", result)
    end

    local status
    status, result = smtp.query(s, "LHLO", smtp.get_domain(host))
    if not status then
      stdnse.debug1("LHLO with errors or timeout.  Enable --script-trace to see what is happening.")
      return false, string.format("Failed to LHLO: %s", result)
    end
    -- semantics of LHLO are same as EHLO
    status, result = smtp.check_reply("EHLO", result)
    if not status then
      return false, string.format("Received LHLO error: %s", result)
    end

    -- Send STARTTLS command ask the service to start encryption
    status, result = smtp.query(s, "STARTTLS")
    if status then
      status, result = smtp.check_reply("STARTTLS", result)
    end

    if not status then
      starttls_supported(host, port, false)
      stdnse.debug1("STARTTLS failed or unavailable.  Enable --script-trace to see what is happening.")

      -- Send QUIT to clean up server side connection
      smtp.quit(s)
      return false, string.format("Failed to connect to SMTP server: %s", result)
    end
    -- Should have a solid TLS over LMTP session now...
    starttls_supported(host, port, true)
    return true, s
  end,

  lmtp_prepare_tls = tls_reconnect("lmtp_prepare_tls_without_reconnect"),

  mysql_prepare_tls_without_reconnect = function(host, port)
    local s, err = comm.opencon(host, port)
    if not s then
      return false, string.format("Failed to connect to MySQL server: %s", err)
    end
    local status, resp = mysql.receiveGreeting(s)
    if not status then
      return false, string.format("MySQL handshake error: %s", resp)
    end
    if 0 == resp.capabilities & mysql.Capabilities.SwitchToSSLAfterHandshake then
      return false, "MySQL server does not support SSL"
    end
    local clicap = mysql.Capabilities.SwitchToSSLAfterHandshake
    + mysql.Capabilities.LongPassword
    + mysql.Capabilities.LongColumnFlag
    + mysql.Capabilities.SupportsLoadDataLocal
    + mysql.Capabilities.Speaks41ProtocolNew
    + mysql.Capabilities.InteractiveClient
    + mysql.Capabilities.SupportsTransactions
    + mysql.Capabilities.Support41Auth
    local packet = string.pack( "<I2I2I4B c23",
      clicap,
      0,
      16777216,
      mysql.Charset.latin1_COLLATE_latin1_swedish_ci,
      string.rep("\0", 23)
      )
    packet = string.pack("<I4", #packet + (1 << 24)) .. packet
    s:send(packet)
    return true, s
  end,

  mysql_prepare_tls = tls_reconnect("mysql_prepare_tls_without_reconnect"),

  nntp_prepare_tls_without_reconnect = function(host, port)
    local s, err, result = comm.opencon(host, port, "", {lines=1, recv_before=true})
    if not s then
      return false, string.format("Failed to connect to NNTP server: %s", err)
    end

    if not string.match(result, "^200") then
      return false, "NNTP protocol mismatch"
    end

    local status = s:send("STARTTLS\r\n")
    status, result = s:receive_lines(1)

    if not (string.match(result, "^382 ")) then
      starttls_supported(host, port, false)
      stdnse.debug1(string.format("Error: %s", result))
      status = s:send("QUIT\r\n")
      s:close()
      return false, "NNTP server does not support STARTTLS"
    end

    starttls_supported(host, port, true)
    return true, s
  end,

  nntp_prepare_tls = tls_reconnect("nntp_prepare_tls_without_reconnect"),

  pop3_prepare_tls_without_reconnect = function(host, port)
    -- Attempt to negotiate TLS over POP3 for services that support it
    -- Works for POP3 (110)

    -- Open a standard TCP socket
    local s, err, result = comm.opencon(host, port, "", {lines=1, recv_before=true})
    if not s then
      return false, string.format("Failed to connect to POP3 server: %s", err)
    end

    if not string.match(result, "^%+OK") then
      return false, "POP3 protocol mismatch"
    end

    -- Send the STLS message
    local status = s:send("STLS\r\n")
    status, result = s:receive_lines(1)

    if not (string.match(result, "^%+OK")) then
      starttls_supported(host, port, false)
      stdnse.debug1(string.format("Error: %s", result))
      status = s:send("QUIT\r\n")
      return false, "Failed to connect to POP3 server"
    end

    -- Should have a solid TLS over POP3 session now...
    starttls_supported(host, port, true)
    return true, s
  end,

  pop3_prepare_tls = tls_reconnect("pop3_prepare_tls_without_reconnect"),

  postgres_prepare_tls_without_reconnect = function(host, port)
    -- http://www.postgresql.org/docs/devel/static/protocol-message-formats.html
    -- 80877103 is "SSLRequest" in v2 and v3 of Postgres protocol
    local s, resp = comm.opencon(host, port, string.pack(">I4I4", 8, 80877103))
    if not s then
      return false, ("Failed to connect to Postgres server: %s"):format(resp)
    end
    -- v2 has "Y", v3 has "S"
    if string.match(resp, "^[SY]") then
      starttls_supported(host, port, true)
      return true, s
    elseif string.match(resp, "^N") then
      starttls_supported(host, port, false)
      return false, "Postgres server does not support SSL"
    end
    return false, "Unknown response from Postgres server"
  end,

  postgres_prepare_tls = tls_reconnect("postgres_prepare_tls_without_reconnect"),

  smtp_prepare_tls_without_reconnect = function(host, port)
    -- Attempt to negotiate TLS over SMTP for services that support it
    -- Works for SMTP (25) and SMTP Submission (587)

    -- Open a standard TCP socket
    local s, result = smtp.connect(host, port, {lines=1, recv_before=1, ssl=false})
    if not s then
      return false, string.format("Failed to connect to SMTP server: %s", result)
    end

    local status
    status, result = smtp.ehlo(s, smtp.get_domain(host))
    if not status then
      stdnse.debug1("EHLO with errors or timeout.  Enable --script-trace to see what is happening.")
      return false, string.format("Failed to connect to SMTP server: %s", result)
    end

    -- Send STARTTLS command ask the service to start encryption
    status, result = smtp.query(s, "STARTTLS")
    if status then
      status, result = smtp.check_reply("STARTTLS", result)
    end

    if not status then
      starttls_supported(host, port, false)
      stdnse.debug1("STARTTLS failed or unavailable.  Enable --script-trace to see what is happening.")

      -- Send QUIT to clean up server side connection
      smtp.quit(s)
      return false, string.format("Failed to connect to SMTP server: %s", result)
    end
    -- Should have a solid TLS over SMTP session now...
    starttls_supported(host, port, true)
    return true, s
  end,

  smtp_prepare_tls = tls_reconnect("smtp_prepare_tls_without_reconnect"),

  tds_prepare_tls_without_reconnect = function(host, port)
    local tds = mssql.TDSStream:new()
    local status, result = tds:Connect(host, port)
    if not status then return status, result end
    local prelogin = mssql.PreLoginPacket:new()
    prelogin:SetRequestEncryption(true)
    tds:Send( prelogin:ToBytes() )
    status, result = tds:Receive()
    if not status then return status, result end

    local status, preloginResponse = mssql.PreLoginPacket.FromBytes(result)
    if not status then return status, preloginResponse end

    local encryption
    local optype, oppos, oplen, pos = string.unpack('>BI2I2', result)
    while optype ~= mssql.PreLoginPacket.OPTION_TYPE.Terminator do
      --stdnse.debug1("optype: %d, oppos: %x, oplen: %d", optype, oppos, oplen)
      if optype == mssql.PreLoginPacket.OPTION_TYPE.Encryption then
        encryption, pos = string.unpack('B', result, oppos + 1)
        break
      end
      optype, oppos, oplen, pos = string.unpack('>BI2I2', result, pos)
    end
    if not encryption then
      starttls_supported(host, port, false)
      return false, "no encryption option found"
    elseif encryption == 0 then
      starttls_supported(host, port, false)
      return false, "Server refused encryption"
    elseif encryption == 3 then
      starttls_supported(host, port, false)
      return false, "Server does not support encryption"
    end

    starttls_supported(host, port, true)
    return true, WrappedSocket:new(tds._socket, {
        wrap_close = function(self)
          return tds:Disconnect()
        end,
        wrap_receive = function(self)
          -- mostly lifted from mssql.TDSStream.Receive
          -- TODO: Modify that function to allow receiving arbitrary response
          -- types, since it's only because it forces type 0x04 that we had to
          -- do this here (where we expect type 0x12)
          local combinedData = ""
          local readBuffer = ""
          local pos = 1
          local tdsPacketAvailable = true

          -- Large messages (e.g. result sets) can be split across multiple TDS
          -- packets from the server (which could themselves each be split across
          -- multiple TCP packets or SMB messages).
          while ( tdsPacketAvailable ) do
            -- If there is existing data in the readBuffer, see if there's
            -- enough to read the TDS headers for the next packet. If not,
            -- do another read so we have something to work with.
            if #readBuffer < 8 then
              status, result = tds._socket:receive_bytes(8 - readBuffer:len())
              if not status then return status, result end
              readBuffer = readBuffer .. result
            end

            -- TDS packet validity check: packet at least as long as the TDS header
            if #readBuffer < 8 then
              return false, "Server returned short packet"
            end

            -- read in the TDS headers
            local packetType, messageStatus, packetLength
            packetType, messageStatus, packetLength, pos = string.unpack(">BBI2", readBuffer, pos )
            local spid, packetId, window
            spid, packetId, window, pos = string.unpack(">I2BB", readBuffer, pos )

            if packetLength > #readBuffer then
              status, result = tds._socket:receive_bytes(packetLength - #readBuffer)
              if not status then return status, result end
              readBuffer = readBuffer .. result
            end

            -- We've read in an apparently valid TDS packet
            local thisPacketData = readBuffer:sub( pos, packetLength )
            -- Append its data to that of any previous TDS packets
            combinedData = combinedData .. thisPacketData
            -- If we read in data beyond the end of this TDS packet, save it
            -- so that we can use it in the next loop.
            readBuffer = readBuffer:sub( packetLength + 1 )

            -- Check the status flags in the TDS packet to see if the message is
            -- continued in another TDS packet.
            tdsPacketAvailable = (
              (messageStatus & mssql.TDSStream.MESSAGE_STATUS_FLAGS.EndOfMessage)
              ~= mssql.TDSStream.MESSAGE_STATUS_FLAGS.EndOfMessage)
          end

          -- return only the data section ie. without the headers
          return true, combinedData

        end,
        wrap_send = function(self, data)
          return tds:Send(mssql.PacketType.PreLogin, data)
        end,
      })
  end,
  -- no TLS reconnect for TDS because of the wrapped handshake thing.
  tds_prepare_tls = function(host, port)
    return false, "Full SSL connection over TDS not supported"
  end,

  vnc_prepare_tls_without_reconnect = function(host,port)
    local v = vnc.VNC:new( host, port )

    local status, data = v:connect()
    if not status then
      return false, string.format("Failed to connect to VNC server: %s", data)
    end

    status, data = v:handshake()
    if not status then
      return false, string.format("Failed VNC handshake: %s", data)
    end

    local sock = v.socket
    if v:supportsSecType(vnc.VNC.sectypes.VENCRYPT) then

      status, data = v:handshake_vencrypt()
      if not status then
        return false, string.format("Failed VeNCrypt handshake: %s", data)
      end
      local auth_order = {
        -- X509 types are not anonymous, have real certs
        vnc.VENCRYPT_SUBTYPES.X509VNC,
        vnc.VENCRYPT_SUBTYPES.X509SASL,
        vnc.VENCRYPT_SUBTYPES.X509NONE,
        vnc.VENCRYPT_SUBTYPES.X509PLAIN,
        -- TLS types use anonymous DH handshakes
        vnc.VENCRYPT_SUBTYPES.TLSVNC,
        vnc.VENCRYPT_SUBTYPES.TLSSASL,
        vnc.VENCRYPT_SUBTYPES.TLSNONE,
        vnc.VENCRYPT_SUBTYPES.TLSPLAIN,
        -- PLAIN type doesn't use TLS
      }
      local best
      for i=1, #auth_order do
        if tableaux.contains(v.vencrypt.types, auth_order[i]) then
          best = auth_order[i]
          break
        end
      end

      if not best then
        starttls_supported(host, port, false)
        return false, "No TLS VeNCrypt auth subtype received"
      end
      sock:send(string.pack(">I4", best))
      local status, buf = sock:receive_buf(match.numbytes(1), true)
      if not status or string.byte(buf, 1) ~= 1 then
        starttls_supported(host, port, false)
        return false, "VeNCrypt auth subtype refused"
      end
      starttls_supported(host, port, true)
      return true, sock
    elseif v:supportsSecType(vnc.VNC.sectypes.TLS) then
      status = sock:send( string.pack("B", vnc.VNC.sectypes.TLS) )
      if not status then
        starttls_supported(host, port, false)
        return false, "Failed to select TLS authentication type"
      end
    else
      starttls_supported(host, port, false)
      return false, string.format("No TLS auth types supported")
    end
    starttls_supported(host, port, true)
    return true, sock
  end,

  vnc_prepare_tls = tls_reconnect("vnc_prepare_tls_without_reconnect"),

  xmpp_prepare_tls_without_reconnect = function(host,port)
    local sock,status,err,result
    local xmppStreamStart = string.format("<?xml version='1.0' ?>\r\n<stream:stream xmlns:stream='http://etherx.jabber.org/streams' xmlns='jabber:client' to='%s' version='1.0'>\r\n",host.name)
    local xmppStartTLS = "<starttls xmlns='urn:ietf:params:xml:ns:xmpp-tls'/>\r\n"
    sock = nmap.new_socket()
    sock:set_timeout(5000)
    status, err = sock:connect(host, port)
    if not status then
      sock:close()
      stdnse.debug1("Can't send: %s", err)
      return false, "Failed to connect to XMPP server"
    end
    status, err = sock:send(xmppStreamStart)
    if not status then
      stdnse.debug1("Couldn't send: %s", err)
      sock:close()
      return false, "Failed to connect to XMPP server"
    end
    status, result = sock:receive()
    if not status then
      stdnse.debug1("Couldn't receive: %s", err)
      sock:close()
      return false, "Failed to connect to XMPP server"
    end
    status, err = sock:send(xmppStartTLS)
    if not status then
      stdnse.debug1("Couldn't send: %s", err)
      sock:close()
      return false, "Failed to connect to XMPP server"
    end
    status, result = sock:receive()
    if not status then
      stdnse.debug1("Couldn't receive: %s", err)
      sock:close()
      return false, "Failed to connect to XMPP server"
    end
    if string.find(result,"proceed") then
      starttls_supported(host, port, true)
      return true,sock
    end

    status, result = sock:receive() -- might not be in the first reply
    if not status then
      stdnse.debug1("Couldn't receive: %s", err)
      sock:close()
      return false, "Failed to connect to XMPP server"
    end
    if string.find(result,"proceed") then
      starttls_supported(host, port, true)
      return true,sock
    else
      starttls_supported(host, port, false)
      return false, "Failed to connect to XMPP server"
    end
  end,

  xmpp_prepare_tls = function(host, port)
    local ls = xmpp.XMPP:new(host, port, { starttls = true } )
    ls.socket = nmap.new_socket()
    ls.socket:set_timeout(ls.options.timeout * 1000)

    local status, err = ls.socket:connect(host, port)
    if not status then
      return nil
    end

    status, err = ls:connect()
    if not(status) then
      return false, "Failed to connected"
    end
    starttls_supported(host, port, true)
    return true, ls.socket
  end
}


-- A table mapping port numbers to specialized SSL negotiation functions.
local SPECIALIZED_PREPARE_TLS = {
  ftp = StartTLS.ftp_prepare_tls,
  [21] = StartTLS.ftp_prepare_tls,
  nntp = StartTLS.nntp_prepare_tls,
  [119] = StartTLS.nntp_prepare_tls,
  imap = StartTLS.imap_prepare_tls,
  [143] = StartTLS.imap_prepare_tls,
  ldap = StartTLS.ldap_prepare_tls,
  [389] = StartTLS.ldap_prepare_tls,
  lmtp = StartTLS.lmtp_prepare_tls,
  pop3 = StartTLS.pop3_prepare_tls,
  [110] = StartTLS.pop3_prepare_tls,
  postgresql = StartTLS.postgres_prepare_tls,
  [5432] = StartTLS.postgres_prepare_tls,
  smtp = StartTLS.smtp_prepare_tls,
  [25] = StartTLS.smtp_prepare_tls,
  [587] = StartTLS.smtp_prepare_tls,
  mysql = StartTLS.mysql_prepare_tls,
  [3306] = StartTLS.mysql_prepare_tls,
  xmpp = StartTLS.xmpp_prepare_tls,
  [5222] = StartTLS.xmpp_prepare_tls,
  [5269] = StartTLS.xmpp_prepare_tls,
  vnc = StartTLS.vnc_prepare_tls,
  [5900] = StartTLS.vnc_prepare_tls,
  ["ms-sql-s"] = StartTLS.tds_prepare_tls
}

local SPECIALIZED_PREPARE_TLS_WITHOUT_RECONNECT = {
  ftp = StartTLS.ftp_prepare_tls_without_reconnect,
  [21] = StartTLS.ftp_prepare_tls_without_reconnect,
  nntp = StartTLS.nntp_prepare_tls_without_reconnect,
  [119] = StartTLS.nntp_prepare_tls_without_reconnect,
  imap = StartTLS.imap_prepare_tls_without_reconnect,
  [143] = StartTLS.imap_prepare_tls_without_reconnect,
  ldap = StartTLS.ldap_prepare_tls_without_reconnect,
  [389] = StartTLS.ldap_prepare_tls_without_reconnect,
  lmtp = StartTLS.lmtp_prepare_tls_without_reconnect,
  pop3 = StartTLS.pop3_prepare_tls_without_reconnect,
  [110] = StartTLS.pop3_prepare_tls_without_reconnect,
  postgresql = StartTLS.postgres_prepare_tls_without_reconnect,
  [5432] = StartTLS.postgres_prepare_tls_without_reconnect,
  smtp = StartTLS.smtp_prepare_tls_without_reconnect,
  [25] = StartTLS.smtp_prepare_tls_without_reconnect,
  [587] = StartTLS.smtp_prepare_tls_without_reconnect,
  mysql = StartTLS.mysql_prepare_tls_without_reconnect,
  [3306] = StartTLS.mysql_prepare_tls_without_reconnect,
  xmpp = StartTLS.xmpp_prepare_tls_without_reconnect,
  [5222] = StartTLS.xmpp_prepare_tls_without_reconnect,
  [5269] = StartTLS.xmpp_prepare_tls_without_reconnect,
  vnc = StartTLS.vnc_prepare_tls_without_reconnect,
  [5900] = StartTLS.vnc_prepare_tls_without_reconnect,
}

-- these can't do reconnect_ssl
local SPECIALIZED_WRAPPED_TLS_WITHOUT_RECONNECT = {
  ["ms-sql-s"] = StartTLS.tds_prepare_tls_without_reconnect,
}

-- Wrap the specialized connection function with a check for previous fail
local function wrap_special_with_reg_check(special)
  return special and function(host, port)
    local oldfail = check_starttls_failed(host, port)
    if oldfail then
      return false, "Previous STARTTLS attempt failed"
    else
      local result = table.pack(special(host, port))
      local mutex = nmap.mutex(host.registry.starttls)
      pcall(mutex, "done")
      return table.unpack(result)
    end
  end
end

--- Get a specialized SSL connection function without starting SSL
--
-- For protocols that require some sort of START-TLS setup, this function will
-- return a function that can be used to produce a socket that is ready for SSL
-- messages.
-- @param port A port table with 'number' and 'service' keys
-- @return A STARTTLS function or nil
function getPrepareTLSWithoutReconnect(port)
  if port.protocol == 'udp' then
    return nil
  end
  if ( port.version and port.version.service_tunnel == 'ssl') then
    return nil
  end
  local special = (SPECIALIZED_PREPARE_TLS_WITHOUT_RECONNECT[port.service] or
    SPECIALIZED_PREPARE_TLS_WITHOUT_RECONNECT[port.number] or
    SPECIALIZED_WRAPPED_TLS_WITHOUT_RECONNECT[port.service] or
    SPECIALIZED_WRAPPED_TLS_WITHOUT_RECONNECT[port.number])
  return wrap_special_with_reg_check(special)
end

--- Get a specialized SSL connection function to create an SSL socket
--
-- For protocols that require some sort of START-TLS setup, this function will
-- return a function that can be used to produce an SSL-connected socket.
-- @param port A port table with 'number' and 'service' keys
-- @return A STARTTLS function or nil
function isPortSupported(port)
  if port.protocol == 'udp' then
    return nil
  end
  if ( port.version and port.version.service_tunnel == 'ssl') then
    return nil
  end
  local special = (SPECIALIZED_PREPARE_TLS[port.service] or
    SPECIALIZED_PREPARE_TLS[port.number])
  return wrap_special_with_reg_check(special)
end

-- returns a function that yields a new tls record each time it is called
local function get_record_iter(sock)
  local buffer = ""
  local i = 1
  local fragment
  return function ()
    local record, more
    i, record, more = tls.record_read(buffer, i, fragment)
    if record == nil then
      if not more then
        return nil, "no more"
      end
      local status, err
      status, buffer, err = tls.record_buffer(sock, buffer, i)
      if not status then
        return nil, err
      end
      i, record = tls.record_read(buffer, i, fragment)
      if record == nil then
        return nil, "done"
      end
    end
    fragment = record.fragment
    return record
  end
end

local function handshake_cert (socket)
    -- logic mostly lifted from ssl-enum-ciphers
    -- TODO: implement TLSv1.3 handshake encryption so we can decrypt the
    -- Certificate message. Until then, we don't attempt TLSv1.3
    local hello = tls.client_hello({protocol="TLSv1.2"})
    local status, err = socket:send(hello)
    if not status then
      return false, "Failed to send to server"
    end

    local get_next_record = get_record_iter(socket)
    local records = {}
    local done = false
    while not done do
      local record
      record, err = get_next_record()
      if not record then
        stdnse.debug1("no record: %s", err)
        break
      end
      -- Collect message bodies into one record per type
      records[record.type] = records[record.type] or record
      for j = 1, #record.body do -- no ipairs because we append below
        local b = record.body[j]
        done = ((record.type == "alert" and b.level == "fatal") or
          (record.type == "handshake" and b.type == "server_hello_done"))
        table.insert(records[record.type].body, b)
      end
    end

    local handshake = records.handshake
    if not handshake then
      return false, "Server did not handshake"
    end

    local certs
    for i, b in ipairs(handshake.body) do
      if b.type == "certificate" then
        certs = b
        break
      end
    end
    if not certs or not next(certs.certificates) then
      return false, "Server sent no certificate"
    end

    local cert, err = parse_ssl_certificate(certs.certificates[1])
    if not cert then
      return false, ("Unable to parse cert: %s"):format(err)
    end
    return true, cert
end

--- Gets a certificate for the given host and port
-- The function will attempt to START-TLS for the ports known to require it.
-- @param host table as received by the script action function
-- @param port table as received by the script action function
-- @return status true on success, false on failure
-- @return cert userdata containing the SSL certificate, or error message on
--         failure.
function getCertificate(host, port)
  local mutex = nmap.mutex("sslcert-cache-mutex")
  mutex "lock"

  local cache = host.registry["ssl-cert"]
  if not cache then
    cache = {}
    host.registry["ssl-cert"] = cache
  end
  local key = ("%d%s"):format(port.number, port.protocol)
  local cert = cache[key]

  if cert then
    stdnse.debug2("sslcert: Returning cached SSL certificate")
    mutex "done"
    return true, cert
  end

  local wrapper, specialized
  if (port.protocol == "tcp") then
    wrapper = SPECIALIZED_WRAPPED_TLS_WITHOUT_RECONNECT[port.service] or SPECIALIZED_WRAPPED_TLS_WITHOUT_RECONNECT[port.number]
    local special_table = have_openssl and SPECIALIZED_PREPARE_TLS or SPECIALIZED_PREPARE_TLS_WITHOUT_RECONNECT
    specialized = special_table[port.service] or special_table[port.number]
  end

  local status = false

  -- If we don't already know the service is TLS wrapped check to see if we
  -- have to use a wrapper and do a manual handshake
  if wrapper and port.version.service_tunnel ~= 'ssl' then
    local socket
    status, socket = wrapper(host, port)
    if not status then
      stdnse.debug1("Wrapper function error: %s", socket)
    else
      status, cert = handshake_cert(socket)
      socket:close()
    end
  end

  -- If that didn't work, see if we need a specialized connection method
  if not status and specialized and port.version.service_tunnel ~= 'ssl' then
    local socket
    status, socket = specialized(host, port)
    if not status then
      stdnse.debug1("Specialized function error: %s", socket)
    else
      if have_openssl then
        cert = socket:get_ssl_certificate()
        status = not not cert
      else
        status, cert = handshake_cert(socket)
      end
      socket:close()
    end
  end

  -- Now try to connect with Nsock's SSL connection
  if not status and have_openssl then
    local socket, errmsg = comm.opencon(host, port, nil, {proto="ssl"})
    if not socket then
      stdnse.debug1("SSL connect error: %s", errmsg)
    else
      cert = socket:get_ssl_certificate()
      status = not not cert
      socket:close()
    end
  end

  -- Finally, try to connect and manually handshake (maybe more tolerant of TLS
  -- insecurity than OpenSSL)
  -- TODO: DTLS handshaking
  if not status and port.protocol == "tcp" then
    local socket = nmap.new_socket()
    local errmsg
    status, errmsg = socket:connect(host, port)
    if not status then
      stdnse.debug1("Connect error: %s", errmsg)
    else
      status, cert = handshake_cert(socket)
      socket:close()
    end
  end

  if not status then
    mutex "done"
    return false, "No certificate found"
  end

  cache[key] = cert
  mutex "done"
  return true, cert
end



return _ENV;
