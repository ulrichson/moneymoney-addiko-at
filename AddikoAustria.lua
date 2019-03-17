WebBanking {
  version = 1.0,
  url = "https://onlinebanking.addiko.at/",
  services = {"Addiko Bank Österreich"},
  description = string.format(MM.localizeText("Get balance and transactions for %s"), "Addiko Bank Österreich")
}

local debug = false
local overviewPage
local ignoreSince = false -- ListAccounts sets this to true in order to get all transaction in the past

local function strToAmount(str)
  str = string.gsub(str, "[^-,%d]", "")
  str = string.gsub(str, ",", ".")
  return tonumber(str)
end

local function strToDate(str)
  local y, m, d = string.match(str, "(%d%d%d%d)-(%d%d)-(%d%d)")
  if d and m and y then
    return os.time {year = y, month = m, day = d, hour = 0, min = 0, sec = 0}
  end
end

local function trim(s)
  local r = s:gsub("^%s*(.-)%s*$", "%1")
  r = r:gsub("%s+", " ")
  return r
end

local function getViewStateFromHtml(html)
  return html:xpath("//input[@name='javax.faces.ViewState']"):attr("value")
end

local function getViewStateFromContent(content)
  local viewState = string.match(content, '<update id="[%w_:]+javax.faces.ViewState:%w+">.+</update>')
  local s1, e1 = string.find(viewState, "<![CDATA[", nil, true)
  local s2, e2 = string.find(viewState, "]]>", nil, true)
  viewState = string.sub(viewState, e1 + 1, s2 - 1)
  return viewState
end

local function getTransactionsDownloadLinkFromContent(content)
  local s1, e1 = string.find(content, "<![CDATA[Download.download('", nil, true)
  local s2, e2 = string.find(content, "',false);]]>", nil, true)
  local link = string.sub(content, e1 + 1, s2 - 1)
  return link
end

-- Inspired by https://github.com/gharlan/moneymoney-shoop
local function parseCSV(csv, ignoreHeader, rowCallback)
  csv = csv .. "\n"
  local len = string.len(csv)
  local cols = {}
  local field = ""
  local quoted = false
  local start = false
  local headerPassed = true
  if ignoreHeader then
    headerPassed = false
  end

  local i = 1
  while i <= len do
    local c = string.sub(csv, i, i)

    if not headerPassed then
      if c == "\n" then
        headerPassed = true
      end
    elseif quoted then
      if c == '"' then
        if i + 1 <= len and string.sub(csv, i + 1, i + 1) == '"' then
          -- Escaped quotation mark.
          field = field .. c
          i = i + 1
        else
          -- End of quotaton.
          quoted = false
        end
      else
        field = field .. c
      end
    else
      if start and c == '"' then
        -- Begin of quotation.
        quoted = true
      elseif c == ";" then
        -- Field separator.
        table.insert(cols, field)
        field = ""
        start = true
      elseif c == "\r" then
        -- Ignore carriage return.
      elseif c == "\n" then
        -- New line. Call callback function.
        table.insert(cols, field)
        rowCallback(cols)
        cols = {}
        field = ""
        quoted = false
        start = true
      else
        field = field .. c
      end
    end
    i = i + 1
  end
end

local function JSFAjaxRequest(url, parameter, viewState)
  local headers = {}
  headers["Accept"] = "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8"
  headers["Faces-Request"] = "partial/ajax"

  local urlParameter = "javax.faces.ViewState=" .. MM.urlencode(viewState) .. "&javax.faces.partial.ajax=true"

  for key, value in pairs(parameter) do
    if value == nil or value == "" then
      urlParameter = urlParameter .. "&" .. MM.urlencode(key)
    else
      urlParameter = urlParameter .. "&" .. MM.urlencode(key) .. "=" .. MM.urlencode(value)
    end
  end

  return (connection:request("POST", url, urlParameter, "application/x-www-form-urlencoded; charset=UTF-8", headers))
end

function SupportsBank(protocol, bankCode)
  return protocol == ProtocolWebBanking and bankCode == "Addiko Bank Österreich"
end

function InitializeSession(protocol, bankCode, username, username2, password, username3)
  local loginPage

  connection = Connection()

  loginPage = HTML(connection:get(url))

  local publicKey = loginPage:xpath("//*[@id='modaloverlay']/div/div/div[2]/div[5]/div[2]/script"):text()

  local publicKeyParameter = {}
  for str in publicKey:gmatch("'[abcdef%d]+'") do
    table.insert(publicKeyParameter, str)
  end

  local modulusStr = publicKeyParameter[1]:gsub("'", "")
  local exponentStr = publicKeyParameter[2]:gsub("'", "")
  local modulus = MM.hexToBin(modulusStr)
  local exponent = MM.hexToBin(exponentStr)

  -- The `space` is the salt
  local encrypted = MM.rsaPkcs1(modulus, exponent, (" " .. password))

  local ciphertext = string.lower(MM.binToHex(encrypted))

  local parameter = {}
  parameter["loginform:ignored-ids"] = ""
  parameter["loginform:userId"] = username
  parameter["loginform:userName"] = username2
  parameter["loginform:password.encrypted"] = ciphertext
  parameter["loginform:loginToken"] = ""
  parameter["loginform:signature"] = ""
  parameter["loginform_SUBMIT"] = "1"
  parameter["javax.faces.behavior.event"] = "click"
  parameter["javax.faces.source"] = "loginform:loginButton"
  parameter["javax.faces.partial.resetValues"] = "true"
  parameter["javax.faces.partial.execute"] = "loginform"
  parameter["javax.faces.partial.render"] = "loginform"
  parameter["loginform"] = "loginform"

  local viewState = loginPage:xpath("//*[@id='loginform']//input[@name='javax.faces.ViewState']"):attr("value")

  JSFAjaxRequest("/banking/login.xhtml", parameter, viewState)

  overviewPage = HTML(connection:get("/banking/main.xhtml"))

  local logoutLink = overviewPage:xpath("//*[@id='userarea:logout-link']"):text()

  if string.match(logoutLink, "Logout") then
    MM.printStatus("Login successful")
  else
    MM.printStatus("Login failed")
    return LoginFailed
  end
end

function ListAccounts(knownAccounts)
  local accounts = {}
  local owner = trim(overviewPage:xpath("//*[@class='verfueger-name']"):text())

  overviewPage:xpath("//*[@id='content:produkte-tab:form:produkte:produkteTable:table_data']"):each(
    function(index, element)
      local type
      local name
      local productAndName = element:xpath("//span[@class='produkt-description']"):text()

      if string.match(productAndName, "Tagesgeld") then
        name = "Addiko Tagesgeld"
        type = AccountTypeSavings
      -- elseif string.match(productAndName, "Festgeld") then
      --   name = "Addiko Festgeld"
      --   type = AccountTypeFixedTermDeposit
      end

      if type then
        local iban = element:xpath("//*[@class='produkt-titel']//*[@class='iban']"):text():gsub("%s+", "")

        local account = {
          name = name,
          owner = owner,
          accountNumber = iban,
          iban = iban,
          currency = "EUR",
          bic = "HSEEAT2KXXX",
          type = type
        }

        if debug then
          print("Fetched account:")
          print("  Name:", account.name)
          print("  Owner:", account.owner)
          print("  IBAN:", account.iban)
          print("  BIC:", account.bic)
          print("  Currency:", account.currency)
          print("  Type:", account.type)
        end

        table.insert(accounts, account)
      end
    end
  )

  return accounts
end

function RefreshAccount(account, since)
  local balance
  local transactions = {}
  local transactionPage
  local currentPageUrl

  -- Select account
  if account.type == AccountTypeSavings then
    currentPageUrl = "/banking/sparkonto"
    transactionPage = HTML(connection:get(currentPageUrl))
  else
    error("Account type " .. account.type .. " is currently not supported")
  end

  local result
  local parameter = {}
  local url = "/banking/main.xhtml"

  -- Open custom time range dialog
  parameter["content:kontenumsaetze-tab:form:kontoUmsaetze:umsatzTable:zeitraumauswahl:inline-period"] =
    "GENERAL_CUSTOM"
  parameter["content:kontenumsaetze-tab:form:kontoUmsaetze:umsatzTable:umsaetze-filter:filter-selection"] = "ALLE"
  parameter["content:kontenumsaetze-tab:form:kontoUmsaetze:umsatzTable:sortierung:box"] =
    "DESC_kontoumsaetze-sortby-default"
  parameter["content:kontenumsaetze-tab:form:kontoUmsaetze:umsatzTable:sortierung:boxXS"] =
    "DESC_kontoumsaetze-sortby-default"
  parameter["content:kontenumsaetze-tab:form:kontoUmsaetze:umsatzTable:table_selection"] = "[]"
  parameter["content:kontenumsaetze-tab:form:kontoUmsaetze:umsatzTable:table_subselection"] = "[]"
  parameter["content:kontenumsaetze-tab:form:kontoUmsaetze:umsatzTable:table_rowexpansion"] = "[]"
  parameter["content:kontenumsaetze-tab:form:kontoUmsaetze:umsatzTable:table_clickedElementId"] = ""
  parameter["content:kontenumsaetze-tab:form:kontoUmsaetze:umsatzTable:table_clickedSubElementId"] = ""
  parameter["content:kontenumsaetze-tab:form:kontoUmsaetze:umsatzTable:table:paginator:pageselect"] = "0"
  parameter["content:kontenumsaetze-tab:form_SUBMIT"] = "1"
  parameter["javax.faces.behavior.event"] = "valueChange"
  parameter["javax.faces.source"] =
    "content:kontenumsaetze-tab:form:kontoUmsaetze:umsatzTable:zeitraumauswahl:inline-period"
  parameter["javax.faces.partial.execute"] =
    "content:kontenumsaetze-tab:form:kontoUmsaetze:umsatzTable:zeitraumauswahl:inline-period"
  parameter["javax.faces.partial.render"] = "contentarea"
  parameter["content:kontenumsaetze-tab:form"] = "content:kontenumsaetze-tab:form"

  local content, charset, mime = JSFAjaxRequest(url, parameter, getViewStateFromHtml(transactionPage))

  -- Set time filter
  parameter = {}

  -- ignoreSince and "01.01.1970" or MM.localizeDate("dd.MM.yyyy", since)
  parameter["overlay-zeitraumauswahl:overlayForm:daterange:von:date"] =
    ignoreSince and "01.01.1970" or MM.localizeDate("dd.MM.yyyy", since)
  parameter["overlay-zeitraumauswahl:overlayForm:daterange:bis:date"] = os.date("%Y-%m-%d", os.time() + 48 * 60 * 60)
  parameter["overlay-zeitraumauswahl:overlayForm:daterange:range"] = "true"
  parameter["overlay-zeitraumauswahl:overlayForm_SUBMIT"] = "1"
  parameter["javax.faces.behavior.event"] = "action"
  parameter["javax.faces.source"] = "overlay-zeitraumauswahl:save"
  parameter["javax.faces.partial.execute"] = "overlay-zeitraumauswahl:overlayForm"
  parameter["javax.faces.partial.render"] = "overlay-zeitraumauswahl:overlayForm"
  parameter["overlay-zeitraumauswahl:overlayForm"] = "overlay-zeitraumauswahl:overlayForm"

  content, charset, mime = JSFAjaxRequest(url, parameter, getViewStateFromContent(content))

  -- Select Export
  parameter = {}
  parameter["content:kontenumsaetze-tab:form:kontoUmsaetze:umsatzTable:zeitraumauswahl:inline-period"] =
    "GENERAL_CUSTOM_ACTIVE"
  parameter["content:kontenumsaetze-tab:form:kontoUmsaetze:umsatzTable:umsaetze-filter:filter-selection"] = "ALLE"
  parameter["content:kontenumsaetze-tab:form:kontoUmsaetze:umsatzTable:sortierung:box"] =
    "DESC_kontoumsaetze-sortby-default"
  parameter["content:kontenumsaetze-tab:form:kontoUmsaetze:umsatzTable:sortierung:boxXS"] =
    "DESC_kontoumsaetze-sortby-default"
  parameter["content:kontenumsaetze-tab:form:kontoUmsaetze:umsatzTable:table_selection"] = "[]"
  parameter["content:kontenumsaetze-tab:form:kontoUmsaetze:umsatzTable:table_subselection"] = "[]"
  parameter["content:kontenumsaetze-tab:form:kontoUmsaetze:umsatzTable:table_rowexpansion"] = "[]"
  parameter["content:kontenumsaetze-tab:form:kontoUmsaetze:umsatzTable:table_clickedElementId"] = ""
  parameter["content:kontenumsaetze-tab:form:kontoUmsaetze:umsatzTable:table_clickedSubElementId"] = ""
  parameter["content:kontenumsaetze-tab:form:kontoUmsaetze:umsatzTable:table:paginator:pageselect"] = "0"
  parameter["content:kontenumsaetze-tab:form_SUBMIT"] = "1"
  parameter["javax.faces.behavior.event"] = "action"
  parameter["javax.faces.source"] = "content:kontenumsaetze-tab:form:kontoUmsaetze:umsatzTable:startExportSmall"
  parameter["javax.faces.partial.execute"] =
    "content:kontenumsaetze-tab:form:kontoUmsaetze:umsatzTable:startExportSmall"
  parameter["javax.faces.partial.render"] = "content:kontenumsaetze-tab:form"
  parameter["content:kontenumsaetze-tab:form"] = "content:kontenumsaetze-tab:form"

  content, charset, mime = JSFAjaxRequest(url, parameter, getViewStateFromContent(content))

  -- Select "export all"
  parameter = {}
  parameter["content:kontenumsaetze-tab:form:kontoUmsaetze:umsatzTable:table_selection"] = "[]"
  parameter["content:kontenumsaetze-tab:form:kontoUmsaetze:umsatzTable:table_subselection"] = "[]"
  parameter["content:kontenumsaetze-tab:form:kontoUmsaetze:umsatzTable:table_rowexpansion"] = "[]"
  parameter["content:kontenumsaetze-tab:form:kontoUmsaetze:umsatzTable:table_clickedElementId"] = ""
  parameter["content:kontenumsaetze-tab:form:kontoUmsaetze:umsatzTable:table_clickedSubElementId"] = ""
  parameter["content:kontenumsaetze-tab:form:kontoUmsaetze:umsatzTable:table:paginator:pageselect"] = "0"
  parameter["content:kontenumsaetze-tab:form_SUBMIT"] = "1"
  parameter["javax.faces.behavior.event"] = "action"
  parameter["javax.faces.source"] = "content:kontenumsaetze-tab:form:kontoUmsaetze:umsatzTable:export:exportAll"
  parameter["javax.faces.partial.execute"] =
    "content:kontenumsaetze-tab:form:kontoUmsaetze:umsatzTable:export:exportAll"
  parameter["javax.faces.partial.render"] = "content:kontenumsaetze-tab:form contentarea"
  parameter["content:kontenumsaetze-tab:form"] = "content:kontenumsaetze-tab:form"

  content, charset, mime = JSFAjaxRequest(url, parameter, getViewStateFromContent(content))

  -- Trigger CSV download
  parameter = {}
  parameter["sammelSplitCsv"] = "false"
  parameter["aktuellerSaldo"] = "true"
  parameter["tagesSalden"] = "true"
  parameter["sammelSplitPdf"] = "false"
  parameter["overlay-umsatzexport:overlayForm_SUBMIT"] = "1"
  parameter["javax.faces.behavior.event"] = "action"
  parameter["javax.faces.source"] = "overlay-umsatzexport:csvDownload"
  parameter["javax.faces.partial.execute"] = "overlay-umsatzexport:overlayForm"
  parameter["javax.faces.partial.render"] = "overlay-umsatzexport:overlayForm"
  parameter["overlay-umsatzexport:overlayForm"] = "overlay-umsatzexport:overlayForm"

  content, charset, mime = JSFAjaxRequest(url, parameter, getViewStateFromContent(content))

  -- Get transactions from CSV
  local csv = connection:get(getTransactionsDownloadLinkFromContent(content))
  local transactions = {}
  parseCSV(
    csv,
    true,
    function(fields)
      if #fields < 10 then
        return
      end

      local amount = strToAmount(fields[8])
      local accountNumber = trim(fields[1]):gsub("%s+", "")
      local purpose = trim(fields[10])
      local name = account.owner

      -- Received transaction
      if amount > 0 then
        local senderName, senderIBAN = string.match(purpose, "(.+)%s+(IBAN:%s+%a%a%d%d[%d%s]+)")
        senderName = trim(senderName)
        senderIBAN = string.sub(senderIBAN, 7)
        senderIBAN = senderIBAN:gsub("%s+", "")

        if senderName ~= nil and senderName ~= "" then
          name = senderName
        end

        if senderIBAN ~= nil and senderIBAN ~= "" then
          accountNumber = senderIBAN
        end
      end

      -- CSV Header: IBAN;Auszugsnummer;Buchungsdatum;Valutadatum;Umsatzzeit;Zahlungsreferenz;Waehrung;Betrag;Buchungstext;Umsatztext
      local transaction = {
        name = name,
        accountNumber = accountNumber,
        bookingDate = strToDate(fields[3]),
        valueDate = strToDate(fields[4]),
        purposeCode = trim(fields[6]),
        currency = trim(fields[7]),
        amount = amount,
        bookingText = trim(fields[9]),
        purpose = purpose,
        booked = true
      }

      if debug then
        print("Transaction:")
        print("  Booking Date:", transaction.bookingDate)
        print("  Value Date:", transaction.valueDate)
        print("  Amount:", transaction.amount)
        print("  Currency:", transaction.currency)
        print("  Booking Text:", transaction.bookingText)
        print("  Purpose:", (transaction.purpose and transaction.purpose or "-"))
        print("  Purpose Code:", (transaction.purposeCode and transaction.purposeCode or "-"))
        print("  Name:", (transaction.name and transaction.name or "-"))
        print("  Bank Code:", (transaction.bankCode and transaction.bankCode or "-"))
        print("  Account Number:", (transaction.accountNumber and transaction.accountNumber or "-"))
      end

      table.insert(transactions, transaction)
    end
  )

  -- Get balance
  local balance = strToAmount(transactionPage:xpath("//*[@id='ueberblick:form']/div[3]/div/div[2]/span/span[1]"):text())

  if debug then
    print("Balance: " .. balance)
  end

  return {balance = balance, transactions = transactions}
end

function EndSession()
  local parameter = {}
  parameter["userarea_SUBMIT"] = "1"
  parameter["javax.faces.behavior.event"] = "action"
  parameter["userarea:logout-link"] = ""
  parameter["javax.faces.partial.execute"] = "userarea:logout-link"
  parameter["userarea"] = "userarea"

  JSFAjaxRequest("/banking/main.xhtml", parameter, getViewStateFromHtml(overviewPage))
end
