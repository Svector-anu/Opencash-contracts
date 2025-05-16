// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

// Uniswap Router interface
interface IUniswapV2Router02 {
    function swapExactTokensForTokens(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external returns (uint[] memory amounts);
    
    function getAmountsOut(uint amountIn, address[] calldata path) 
        external view returns (uint[] memory amounts);
}

/**
 * @title SimpleGateway
 * @dev A contract that allows users to create crypto exchange orders
 * and processes them through an aggregator. Now with Uniswap integration!
 */
contract SimpleGateway is Ownable, ReentrancyGuard {
    // State variables
    address public treasury;
    uint256 public protocolFeePercent; // Fee in basis points (100 = 1%)
    uint256 public orderIdCounter;
    IUniswapV2Router02 public uniswapRouter;
    
    // Mapping to track supported tokens
    mapping(address => bool) public supportedTokens;
    
    // Order struct to store order information
    struct Order {
        address token;
        uint256 amount;
        uint256 rate;
        address creator;
        address refundAddress;
        address liquidityProvider;
        bool isFulfilled;
        bool isRefunded;
        uint256 timestamp;
    }
    
    // Mapping to store orders by ID
    mapping(uint256 => Order) public orders;
    
    // Events
    event OrderCreated(uint256 orderId, address token, uint256 amount, uint256 rate, address refundAddress, address liquidityProvider);
    event OrderFulfilled(uint256 orderId, address liquidityProvider);
    event OrderRefunded(uint256 orderId);
    event TokenSupportUpdated(address token, bool isSupported);
    event TreasuryUpdated(address newTreasury);
    event ProtocolFeeUpdated(uint256 newFeePercent);
    event RouterUpdated(address uniswapRouter);
    event SwapExecuted(address fromToken, address toToken, uint256 amountIn, uint256 amountOut);
    
    // Constructor
    constructor(address _treasury, uint256 _protocolFeePercent) {
        require(_treasury != address(0), "Invalid treasury address");
        require(_protocolFeePercent <= 1000, "Fee too high"); // Max 10%
        
        treasury = _treasury;
        protocolFeePercent = _protocolFeePercent;
    }
    
    /**
     * @dev Sets the Uniswap Router address
     * @param _router The address of the Uniswap Router
     */
    function setUniswapRouter(address _router) external onlyOwner {
        require(_router != address(0), "Invalid router address");
        uniswapRouter = IUniswapV2Router02(_router);
        emit RouterUpdated(_router);
    }
    
    /**
     * @dev Sets token support status
     * @param _token The token address
     * @param _isSupported Whether the token is supported
     */
    function setTokenSupport(address _token, bool _isSupported) external onlyOwner {
        require(_token != address(0), "Invalid token address");
        supportedTokens[_token] = _isSupported;
        emit TokenSupportUpdated(_token, _isSupported);
    }
    
    /**
     * @dev Updates the treasury address
     * @param _treasury The new treasury address
     */
    function setTreasury(address _treasury) external onlyOwner {
        require(_treasury != address(0), "Invalid treasury address");
        treasury = _treasury;
        emit TreasuryUpdated(_treasury);
    }
    
    /**
     * @dev Updates the protocol fee percentage
     * @param _protocolFeePercent The new fee percentage in basis points
     */
    function setProtocolFeePercent(uint256 _protocolFeePercent) external onlyOwner {
        require(_protocolFeePercent <= 1000, "Fee too high"); // Max 10%
        protocolFeePercent = _protocolFeePercent;
        emit ProtocolFeeUpdated(_protocolFeePercent);
    }
    
    /**
     * @dev Creates a new exchange order
     * @param _token The token address
     * @param _amount The amount of tokens
     * @param _rate The expected exchange rate
     * @param _refundAddress The address to refund tokens if needed
     * @param _liquidityProvider The address of the liquidity provider
     * @return orderId The ID of the created order
     */
    function createOrder(
        address _token,
        uint256 _amount,
        uint256 _rate,
        address _refundAddress,
        address _liquidityProvider
    ) external nonReentrant returns (uint256 orderId) {
        require(supportedTokens[_token], "Token not supported");
        require(_amount > 0, "Amount must be greater than 0");
        require(_rate > 0, "Rate must be greater than 0");
        require(_refundAddress != address(0), "Invalid refund address");
        require(_liquidityProvider != address(0), "Invalid liquidity provider address");
        
        // Transfer tokens from user to contract
        IERC20 token = IERC20(_token);
        require(token.transferFrom(msg.sender, address(this), _amount), "Transfer failed");
        
        // Calculate protocol fee
        uint256 feeAmount = (_amount * protocolFeePercent) / 10000;
        uint256 netAmount = _amount - feeAmount;
        
        // Transfer fee to treasury and tokens to liquidity provider
        require(token.transfer(treasury, feeAmount), "Fee transfer failed");
        require(token.transfer(_liquidityProvider, netAmount), "Liquidity provider transfer failed");
        
        // Create order
        orderId = orderIdCounter++;
        orders[orderId] = Order({
            token: _token,
            amount: _amount,
            rate: _rate,
            creator: msg.sender,
            refundAddress: _refundAddress,
            liquidityProvider: _liquidityProvider,
            isFulfilled: true, // Auto-fulfilled
            isRefunded: false,
            timestamp: block.timestamp
        });
        
        emit OrderCreated(orderId, _token, _amount, _rate, _refundAddress, _liquidityProvider);
        emit OrderFulfilled(orderId, _liquidityProvider);
    }
    
    /**
     * @dev Creates a new exchange order by first swapping an unsupported token to a supported one
     * @param _inputToken The address of the token to swap from
     * @param _targetToken The supported token to swap to and use for the order
     * @param _inputAmount The amount of input tokens
     * @param _minOutputAmount The minimum amount of target tokens expected from the swap
     * @param _rate The expected exchange rate for the created order
     * @param _refundAddress The address to refund tokens if needed
     * @param _liquidityProvider The address of the liquidity provider
     * @return orderId The ID of the created order
     */
    function createOrderWithSwap(
        address _inputToken,
        address _targetToken,
        uint256 _inputAmount,
        uint256 _minOutputAmount,
        uint256 _rate,
        address _refundAddress,
        address _liquidityProvider
    ) external nonReentrant returns (uint256 orderId) {
        // Validate inputs
        require(address(uniswapRouter) != address(0), "Uniswap router not set");
        require(_inputAmount > 0, "Input amount must be greater than 0");
        require(_minOutputAmount > 0, "Min output amount must be greater than 0");
        require(supportedTokens[_targetToken], "Target token not supported");
        require(_refundAddress != address(0), "Invalid refund address");
        require(_liquidityProvider != address(0), "Invalid liquidity provider address");
        
        // Transfer input tokens from user to contract
        IERC20 inputToken = IERC20(_inputToken);
        require(inputToken.transferFrom(msg.sender, address(this), _inputAmount), "Transfer failed");
        
        // Approve router to spend the input tokens
        require(inputToken.approve(address(uniswapRouter), _inputAmount), "Approval failed");
        
        // Define the swap path
        address[] memory path = new address[](2);
        path[0] = _inputToken;
        path[1] = _targetToken;
        
        uint256 outputAmount;
        
        // Execute the swap with error handling
        try uniswapRouter.swapExactTokensForTokens(
            _inputAmount,
            _minOutputAmount,
            path,
            address(this),
            block.timestamp + 300 // 5 minute deadline
        ) returns (uint[] memory amounts) {
            // The output amount of target tokens we received
            outputAmount = amounts[amounts.length - 1];
            
            emit SwapExecuted(_inputToken, _targetToken, _inputAmount, outputAmount);
        } catch {
            // Refund the user if the swap fails
            require(inputToken.transfer(msg.sender, _inputAmount), "Refund failed");
            revert("Swap failed");
        }
        
        // Calculate protocol fee
        uint256 feeAmount = (outputAmount * protocolFeePercent) / 10000;
        uint256 netAmount = outputAmount - feeAmount;
        
        // Transfer fee to treasury and tokens to liquidity provider
        IERC20 targetToken = IERC20(_targetToken);
        require(targetToken.transfer(treasury, feeAmount), "Fee transfer failed");
        require(targetToken.transfer(_liquidityProvider, netAmount), "Liquidity provider transfer failed");
        
        // Create the order with the swapped tokens
        orderId = orderIdCounter++;
        orders[orderId] = Order({
            token: _targetToken,
            amount: outputAmount,
            rate: _rate,
            creator: msg.sender,
            refundAddress: _refundAddress,
            liquidityProvider: _liquidityProvider,
            isFulfilled: true, // Auto-fulfilled
            isRefunded: false,
            timestamp: block.timestamp
        });
        
        emit OrderCreated(orderId, _targetToken, outputAmount, _rate, _refundAddress, _liquidityProvider);
        emit OrderFulfilled(orderId, _liquidityProvider);
    }
    
    /**
     * @dev Creates a new exchange order by swapping an unsupported token using a custom path
     * @param _path Array of token addresses representing the swap path
     * @param _inputAmount The amount of input tokens
     * @param _minOutputAmount The minimum amount of target tokens expected
     * @param _rate The expected exchange rate for the created order
     * @param _refundAddress The address to refund tokens if needed
     * @param _liquidityProvider The address of the liquidity provider
     * @return orderId The ID of the created order
     */
    function createOrderWithCustomPath(
        address[] calldata _path,
        uint256 _inputAmount,
        uint256 _minOutputAmount,
        uint256 _rate,
        address _refundAddress,
        address _liquidityProvider
    ) external nonReentrant returns (uint256 orderId) {
        // Validate inputs
        require(address(uniswapRouter) != address(0), "Uniswap router not set");
        require(_path.length >= 2, "Path too short");
        require(_inputAmount > 0, "Input amount must be greater than 0");
        require(_minOutputAmount > 0, "Min output amount must be greater than 0");
        require(supportedTokens[_path[_path.length - 1]], "Target token not supported");
        require(_refundAddress != address(0), "Invalid refund address");
        require(_liquidityProvider != address(0), "Invalid liquidity provider address");
        
        // Transfer input tokens from user to contract
        IERC20 inputToken = IERC20(_path[0]);
        require(inputToken.transferFrom(msg.sender, address(this), _inputAmount), "Transfer failed");
        
        // Approve router to spend the input tokens
        require(inputToken.approve(address(uniswapRouter), _inputAmount), "Approval failed");
        
        uint256 outputAmount;
        address targetToken = _path[_path.length - 1];
        
        // Execute the swap with error handling
        try uniswapRouter.swapExactTokensForTokens(
            _inputAmount,
            _minOutputAmount,
            _path,
            address(this),
            block.timestamp + 300 // 5 minute deadline
        ) returns (uint[] memory amounts) {
            // The output amount of target tokens we received
            outputAmount = amounts[amounts.length - 1];
            
            emit SwapExecuted(_path[0], targetToken, _inputAmount, outputAmount);
        } catch {
            // Refund the user if the swap fails
            require(inputToken.transfer(msg.sender, _inputAmount), "Refund failed");
            revert("Swap failed");
        }
        
        // Calculate protocol fee
        uint256 feeAmount = (outputAmount * protocolFeePercent) / 10000;
        uint256 netAmount = outputAmount - feeAmount;
        
        // Transfer fee to treasury and tokens to liquidity provider
        IERC20 targetTokenContract = IERC20(targetToken);
        require(targetTokenContract.transfer(treasury, feeAmount), "Fee transfer failed");
        require(targetTokenContract.transfer(_liquidityProvider, netAmount), "Liquidity provider transfer failed");
        
        // Create the order with the swapped tokens
        orderId = orderIdCounter++;
        orders[orderId] = Order({
            token: targetToken,
            amount: outputAmount,
            rate: _rate,
            creator: msg.sender,
            refundAddress: _refundAddress,
            liquidityProvider: _liquidityProvider,
            isFulfilled: true, // Auto-fulfilled
            isRefunded: false,
            timestamp: block.timestamp
        });
        
        emit OrderCreated(orderId, targetToken, outputAmount, _rate, _refundAddress, _liquidityProvider);
        emit OrderFulfilled(orderId, _liquidityProvider);
    }
    
    /**
     * @dev Estimates the amount of target tokens that will be received after swapping
     * @param _inputToken The token to swap from
     * @param _targetToken The token to swap to
     * @param _inputAmount The amount of input tokens
     * @return The estimated amount of target tokens
     */
    function estimateSwapOutput(
        address _inputToken,
        address _targetToken,
        uint256 _inputAmount
    ) external view returns (uint256) {
        require(address(uniswapRouter) != address(0), "Uniswap router not set");
        
        address[] memory path = new address[](2);
        path[0] = _inputToken;
        path[1] = _targetToken;
        
        uint[] memory amounts = uniswapRouter.getAmountsOut(_inputAmount, path);
        return amounts[1];
    }
    
    /**
     * @dev Estimates the amount of target tokens that will be received after swapping with a custom path
     * @param _path The swap path
     * @param _inputAmount The amount of input tokens
     * @return The estimated amount of target tokens
     */
    function estimateSwapOutputWithPath(
        address[] calldata _path,
        uint256 _inputAmount
    ) external view returns (uint256) {
        require(address(uniswapRouter) != address(0), "Uniswap router not set");
        require(_path.length >= 2, "Path too short");
        
        uint[] memory amounts = uniswapRouter.getAmountsOut(_inputAmount, _path);
        return amounts[_path.length - 1];
    }
    
    /**
     * @dev Gets information about an order
     * @param _orderId The order ID
     * @return token         The token address for this order
     * @return amount        The amount of tokens in the order
     * @return rate          The expected exchange rate
     * @return creator       The address that created the order
     * @return refundAddress The address to refund if the order is cancelled
     * @return liquidityProvider The address of the liquidity provider
     * @return isFulfilled   Whether the order has been fulfilled
     * @return isRefunded    Whether the order has been refunded
     * @return timestamp     The block timestamp when the order was created
     */
    function getOrderInfo(uint256 _orderId) external view returns (
        address token,
        uint256 amount,
        uint256 rate,
        address creator,
        address refundAddress,
        address liquidityProvider,
        bool isFulfilled,
        bool isRefunded,
        uint256 timestamp
    ) {
        Order storage order = orders[_orderId];
        return (
            order.token,
            order.amount,
            order.rate,
            order.creator,
            order.refundAddress,
            order.liquidityProvider,
            order.isFulfilled,
            order.isRefunded,
            order.timestamp
        );
    }
}