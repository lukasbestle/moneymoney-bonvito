-- MoneyMoney extension for bonVito prepaid payment cards
-- https://github.com/lukasbestle/moneymoney-bonvito
--
---------------------------------------------------------
--
-- MIT License
--
-- Copyright (c) 2022 Lukas Bestle
--
-- Permission is hereby granted, free of charge, to any person obtaining a copy
-- of this software and associated documentation files (the "Software"), to deal
-- in the Software without restriction, including without limitation the rights
-- to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
-- copies of the Software, and to permit persons to whom the Software is
-- furnished to do so, subject to the following conditions:
--
-- The above copyright notice and this permission notice shall be included in all
-- copies or substantial portions of the Software.
--
-- THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
-- IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
-- FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
-- AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
-- LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
-- OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
-- SOFTWARE.

WebBanking{
  version     = 1.00,
  url         = "https://secure.bonvito.net/consumer/",
  services    = {"bonVito"},
  description = string.format(
    MM.localizeText("Get balance and transactions for %s"),
    "bonVito"
  )
}

local connection = Connection()

-- define local functions
local parseAmount

-----------------------------------------------------------

---**Checks if this extension can request from a specified bank**
---
---@param protocol protocol Protocol of the bank gateway
---@param bankCode string Bank code or service name
---@return boolean | string `true` or the URL to the online banking entry page if the extension supports the bank, `false` otherwise
function SupportsBank (protocol, bankCode)
  return protocol == ProtocolWebBanking and bankCode == "bonVito"
end

---**Performs the login to the backend**
---
---@param protocol protocol Protocol of the bank gateway
---@param bankCode string Bank code or service name
---@param username string
---@param reserved string Empty, currently not in use
---@param password string
---@return LoginFailed | string | nil # Optional error message
function InitializeSession (protocol, bankCode, username, reserved, password)
  local html = HTML(connection:get(url .. "index.php/login"))

  html:xpath("//input[@name='signin[login]']"):attr("value", username)
  html:xpath("//input[@name='signin[password]']"):attr("value", password)
  html = HTML(connection:request(html:xpath("//input[@name='commit']"):click()))

  local error = html:xpath("//*[@id='error-info']|//*[@class='error_list']")
  if error:length() > 0 then
    local message = error:get(1):text()

    -- invalid credentials
    if message:find("falsch eingegeben") then
      return LoginFailed
    end

    -- other error, return full error message
    return string.format(
      MM.localizeText("The web server %s responded with the error message:\n»%s«\nPlease try again later."),
      "secure.bonvito.net",
      message
    )
  end

  -- ensure that we are indeed logged in
  if html:xpath("//*[@id='logout']/a"):length() < 1 then
    return MM.localizeText("The server responded with an internal error. Please try again later.")
  end

  -- no error, success
  return nil
end

---**Returns a list of accounts that can be refreshed with this extension**
---
---@param knownAccounts Account[] List of accounts that are already known via FinTS/HBCI
---@return NewAccount[] | string # List of accounts that can be requsted with web scraping or error message
function ListAccounts (knownAccounts)
  local html = HTML(connection:get(url .. "discounts.php/vnkonto/paymentStatements"))

  local accounts = {} --[=[@as NewAccount[]]=]
  html:xpath("//table[@id='paymentStatements']/tbody/tr"):each(
    function (_, element)
      -- we use the merchant ID as the account number
      -- (actual account number is not displayed);
      -- the merchant ID and currency can be extracted from the detail URL
      local url = element:xpath("./td[4]/a"):attr("href")
      local merchantId, currency = url:match("id/(%d+)/currency/(%u+)")

      table.insert(accounts, {
        accountNumber = merchantId,
        currency = currency,
        name = element:xpath("./td[1]"):text(),
        portfolio = false,
        type = AccountTypeCreditCard
      })
    end
  )

  return accounts
end

---**Refreshes the balance and transaction of an account**
---
---@param account Account Account that is being refreshed
---@param since timestamp | nil POSIX timestamp of the oldest transaction to return or `nil` for portfolios
---@return AccountResults | string # Web scraping results or error message
function RefreshAccount (account, since)
  -- dynamically construct the target URL from the account data
  local url = string.format(
    url .. "discounts.php/vnkonto/paymentStatementsDetails/id/%s/currency/%s",
    account.accountNumber,
    account.currency
  )

  local html = HTML(connection:get(url))

  local transactions = {} --[=[@as NewTransaction[]]=]
  html:xpath("//table[@id='paymentStatements']/tbody/tr"):each(
    function (_, element)
      local children = element:children()

      -- extract the date
      local datePattern = "(%d%d)%.(%d%d)%.(%d%d)"
      local day, month, year = children:get(1):text():match(datePattern)
      local bookingDate = os.time{day=day, month=month, year="20" .. year}

      -- for better performance, stop after reaching past the since date
      -- even though the HTML response already contains all transactions
      if bookingDate < since then
        return false
      end

      table.insert(transactions, {
        accountNumber = children:get(2):text(),
        amount = parseAmount(children:get(4):text()),
        bookingDate = bookingDate,
        name = children:get(3):text()
      })
    end
  )

  return {
    balance = parseAmount(
      html:xpath("//tr[@class='account-balance-top']/td[2]"):text()
    ),
    transactions = transactions
  }
end

---**Performs the logout from the backend**
---
---@return string? # Optional error message
function EndSession ()
  connection:get(url .. "index.php/logout")
end

-----------------------------------------------------------

---**Parses a string amount in the form "xxx,xx €" into a number**
---
---Values in different currencies are supported as only the numeric
---part is parsed.
---
---@param amount string
---@return number?
function parseAmount (amount)
  local euro, cent = amount:match("(%-?%d+),(%d%d)")
  return tonumber(euro .. "." .. cent)
end
