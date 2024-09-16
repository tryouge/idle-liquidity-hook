package slot

import (
	"math/big"
	"testing"

	"github.com/brevis-network/brevis-sdk/sdk"
	"github.com/brevis-network/brevis-sdk/test"
	"github.com/ethereum/go-ethereum/common"
)

func TestCircuit(t *testing.T) {
	app, err := sdk.NewBrevisApp()
	check(err)

	account := common.HexToAddress("0xd98Be00b5D27fc98112BdE293e487f8D4cA57d07")

	app.AddStorage(sdk.StorageData{
		BlockNum: big.NewInt(255599800),
		Address:  account,
		Slot:     common.BytesToHash(common.LeftPadBytes([]byte{0}, 32)),
		// cast storage 0xd98Be00b5D27fc98112BdE293e487f8D4cA57d07 0 --rpc-url https://arbitrum.llamarpc.com --block 255599800
		Value: common.HexToHash("0x0000008ca041769c0000006fba88b3780003955035f9a274000391cdff2d82a1"),
	}, 0)

	app.AddStorage(sdk.StorageData{
		BlockNum: big.NewInt(255599800),
		Address:  account,
		Slot:     common.BytesToHash(common.LeftPadBytes([]byte{1}, 32)),
		// cast storage 0xd98Be00b5D27fc98112BdE293e487f8D4cA57d07 1 --rpc-url https://arbitrum.llamarpc.com --block 255599800
		Value: common.HexToHash("0x000066edd86b000000000000001565bc751401000000000000001b59f181a092"),
	}, 1)

	appCircuit := &AppCircuit{}
	appCircuitAssignment := &AppCircuit{}

	in, err := app.BuildCircuitInput(appCircuit)
	check(err)

	test.ProverSucceeded(t, appCircuit, appCircuitAssignment, in)

	// cast call 0xd98Be00b5D27fc98112BdE293e487f8D4cA57d07 "getUtilization()(uint256)" --rpc-url https://arbitrum.llamarpc.com --block 255599800
	// utilization 785320331907519211

	// cast call 0xd98Be00b5D27fc98112BdE293e487f8D4cA57d07 "getSupplyRate(uint256)(uint256)" 785320331907519211 --rpc-url https://arbitrum.llamarpc.com --block 255599800
	// supplyRate 971191429
}

func check(err error) {
	if err != nil {
		panic(err)
	}
}
