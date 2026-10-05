--!strict
-- Opt-in server adapter; loading this module does not bind anything or open storage.
local Adapter = {}

function Adapter.store(dataStore)
	return {
		UpdateAsync = function(_, key, transform)
			return dataStore:UpdateAsync(key, function(value, info)
				local nextValue = transform(value)
				if nextValue == nil then
					return nil
				end
				-- Preserve existing user metadata when replacing the value.
				return nextValue,
					if info then info:GetUserIds() else nil,
					if info then info:GetMetadata() else nil
			end)
		end,
	}
end

function Adapter.callback(ledger, onResult)
	return function(receipt)
		local ok, result = pcall(function()
			return ledger:process(receipt)
		end)
		if not ok then
			return Enum.ProductPurchaseDecision.NotProcessedYet
		end
		if onResult then
			pcall(
				onResult,
				{ decision = result.decision, reason = result.reason, attempts = result.attempts }
			)
		end
		return if result.decision == "PurchaseGranted"
			then Enum.ProductPurchaseDecision.PurchaseGranted
			else Enum.ProductPurchaseDecision.NotProcessedYet
	end
end

return Adapter
