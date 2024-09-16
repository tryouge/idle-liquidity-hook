package slot

import (
	"fmt"
	"math/big"

	"github.com/brevis-network/brevis-sdk/sdk"
)

type AppCircuit struct{}

var _ sdk.AppCircuit = &AppCircuit{}

func (c *AppCircuit) Allocate() (maxReceipts, maxSlots, maxTransactions int) {
	return 0, 2, 0
}

var ZERO = sdk.ConstUint248(0)
var ONE = sdk.ConstUint248(1)
var BASE_INDEX_SCALE = sdk.ConstUint248(big.NewInt(1e15))
var FACTOR_SCALE = sdk.ConstUint248(big.NewInt(1e18))

var SUPPLY_KINK = sdk.ConstUint248(new(big.Int).Mul(big.NewInt(85), big.NewInt(1e16)))
var SUPPLY_PER_SECOND_INTEREST_RATE_BASE = ZERO
var SUPPLY_PER_SECOND_INTEREST_RATE_SLOPE_LOW = sdk.ConstUint248(big.NewInt(1236681887))
var SUPPLY_PER_SECOND_INTEREST_RATE_SLOPE_HIGH = sdk.ConstUint248(big.NewInt(114155251141))

func getUtilization(api *sdk.CircuitAPI, slot0 sdk.List[sdk.Uint248], slot1 sdk.List[sdk.Uint248]) sdk.Uint248 {
	baseSupplyIndex := api.Uint248.FromBinary(slot0[:8*8]...)
	baseBorrowIndex := api.Uint248.FromBinary(slot0[8*8 : 16*8]...)
	totalSupplyBase := api.Uint248.FromBinary(slot1[:13*8]...)
	totalBorrowBase := api.Uint248.FromBinary(slot1[13*8 : 26*8]...)

	totalSupply, _ := api.Uint248.Div(api.Uint248.Mul(totalSupplyBase, baseSupplyIndex), BASE_INDEX_SCALE)
	totalBorrow, _ := api.Uint248.Div(api.Uint248.Mul(totalBorrowBase, baseBorrowIndex), BASE_INDEX_SCALE)

	var utilization sdk.Uint248

	if api.Uint248.IsZero(totalSupply) == ONE {
		utilization = ZERO
	} else {
		utilization, _ = api.Uint248.Div(api.Uint248.Mul(totalBorrow, FACTOR_SCALE), totalSupply)
	}

	return utilization
}

func mulFactor(api *sdk.CircuitAPI, n sdk.Uint248, factor sdk.Uint248) sdk.Uint248 {
	quotient, _ := api.Uint248.Div(api.Uint248.Mul(n, factor), FACTOR_SCALE)
	return quotient
}

func getSupplyRate(api *sdk.CircuitAPI, utilization sdk.Uint248) sdk.Uint248 {
	var supplyRate sdk.Uint248

	if api.Uint248.IsGreaterThan(utilization, SUPPLY_KINK) == ONE {
		supplyRate = api.Uint248.Add(
			api.Uint248.Add(
				SUPPLY_PER_SECOND_INTEREST_RATE_BASE,
				mulFactor(api, SUPPLY_PER_SECOND_INTEREST_RATE_SLOPE_LOW, SUPPLY_KINK),
			),
			mulFactor(api, SUPPLY_PER_SECOND_INTEREST_RATE_SLOPE_HIGH, api.Uint248.Sub(utilization, SUPPLY_KINK)),
		)
	} else {
		supplyRate = api.Uint248.Add(
			SUPPLY_PER_SECOND_INTEREST_RATE_BASE,
			mulFactor(api, SUPPLY_PER_SECOND_INTEREST_RATE_SLOPE_LOW, utilization),
		)
	}

	return supplyRate
}

func (c *AppCircuit) Define(api *sdk.CircuitAPI, in sdk.DataInput) error {
	slots := sdk.NewDataStream(api, in.StorageSlots)

	slot0 := api.Bytes32.ToBinary(sdk.GetUnderlying(slots, 0).Value)
	slot1 := api.Bytes32.ToBinary(sdk.GetUnderlying(slots, 1).Value)

	utilization := getUtilization(api, slot0, slot1)
	fmt.Println("utilization", utilization.String())

	supplyRate := getSupplyRate(api, utilization)
	fmt.Println("supplyRate", supplyRate.String())

	api.OutputBytes32(api.ToBytes32(utilization))
	api.OutputBytes32(api.ToBytes32(supplyRate))

	return nil
}
