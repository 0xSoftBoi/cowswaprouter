// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @notice Minimal ERC-20 mock for Wake tests. Supports mint/burn, no access control.
contract MockToken {
    string public name;
    string public symbol;
    uint8  public decimals = 18;
    uint256 public totalSupply;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 amount);
    event Approval(address indexed owner, address indexed spender, uint256 amount);

    constructor(string memory _name, string memory _symbol) {
        name   = _name;
        symbol = _symbol;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply    += amount;
        emit Transfer(address(0), to, amount);
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        return _transfer(msg.sender, to, amount);
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) {
            require(allowed >= amount, "ALLOWANCE");
            allowance[from][msg.sender] = allowed - amount;
        }
        return _transfer(from, to, amount);
    }

    function _transfer(address from, address to, uint256 amount) internal returns (bool) {
        require(balanceOf[from] >= amount, "BAL");
        balanceOf[from] -= amount;
        balanceOf[to]   += amount;
        emit Transfer(from, to, amount);
        return true;
    }
}

interface IERC20Pull {
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

/// @notice Mock CoW relayer — simulates GPv2VaultRelayer by pulling tokens via transferFrom.
/// The real relayer is pre-approved by the executor and calls transferFrom on each deposit.
contract MockRelayer {
    uint256 public depositCount;
    address public lastToken;
    address public lastSender;
    uint256 public lastAmount;

    function deposit(address token, address from, uint256 amount) external {
        depositCount++;
        lastToken  = token;
        lastSender = from;
        lastAmount = amount;
        // Simulate real relayer: pull tokens from the caller (CowTwapExecutor) using approval
        IERC20Pull(token).transferFrom(msg.sender, address(this), amount);
    }
}

/// @notice Mock CoW settler — accepts settle() calls and records count.
contract MockSettler {
    uint256 public settleCount;
    bytes   public lastOrderUid;

    function settle(bytes calldata orderUid) external {
        settleCount++;
        lastOrderUid = orderUid;
    }
}
