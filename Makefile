.PHONY: install test test-contracts test-miner test-validator test-gateway test-client-python test-devnet-e2e clean deploy-testnet deploy-mainnet lint

install:
	cd contracts && forge install
	cd miner && pip install --require-hashes -r requirements-dev.lock && pip install --no-deps -e .
	cd validator && pip install --require-hashes -r requirements-dev.lock && pip install --no-deps -e .
	cd gateway && pip install --require-hashes -r requirements-dev.lock && pip install --no-deps -e .
	cd client/typescript && npm ci
	cd client/python && pip install --require-hashes -r requirements-dev.lock && pip install --no-deps -e .

test: test-contracts test-miner test-validator test-gateway test-client-python test-devnet-e2e

test-contracts:
	cd contracts && forge test -vvv

test-miner:
	cd miner && PYTHONPATH=src pytest

test-validator:
	cd validator && PYTHONPATH=src pytest

test-gateway:
	cd gateway && PYTHONPATH=src pytest

test-client-python:
	cd client/python && PYTHONPATH=. pytest

test-devnet-e2e:
	PYTHONPATH=client/python:gateway/src:miner/src:validator/src python scripts/devnet_e2e.py

lint:
	cd contracts && forge fmt --check
	cd miner && ruff check src tests
	cd validator && ruff check src tests
	cd gateway && ruff check src tests
	ruff check scripts/devnet_e2e.py
	cd client/typescript && npm run lint

deploy-testnet:
	cd contracts && forge script script/Deploy.s.sol --rpc-url $(INK_SEPOLIA_RPC) --broadcast --verify

deploy-mainnet:
	@echo "Refusing to deploy to mainnet without explicit confirmation."
	@echo "Mainnet hosts the L1 BrainNFT + bridge adapter (DeployMainnet), NOT the L2 stack (Deploy)."
	@echo "Run: cd contracts && forge script script/DeployMainnet.s.sol --rpc-url $$MAINNET_RPC --broadcast --verify"

clean:
	cd contracts && forge clean
	rm -rf miner/.pytest_cache validator/.pytest_cache
	rm -rf client/typescript/node_modules client/typescript/dist
