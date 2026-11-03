$ErrorActionPreference='Stop'
$straightVivadoBin='D:\Vivado2019\Vivado\2019.1\bin'
$env:PROCESSOR_ARCHITECTURE='AMD64'
Push-Location -LiteralPath $PSScriptRoot
try {
    & "$straightVivadoBin\xvlog.bat" --sv 'straight_route_controller.sv' 'tb_straight_route_controller.sv'
    if($LASTEXITCODE -ne 0){throw 'xvlog failed'}
    & "$straightVivadoBin\xelab.bat" tb_straight_route_controller -s straight_route_sim --debug typical
    if($LASTEXITCODE -ne 0){throw 'xelab failed'}
    & "$straightVivadoBin\xsim.bat" straight_route_sim -runall -log simulation.log
    if($LASTEXITCODE -ne 0){throw 'xsim failed'}
    if(-not(Select-String -LiteralPath 'simulation.log' -Pattern 'STRAIGHT_ROUTE_SIM_PASS' -Quiet)){throw 'Simulation missing PASS marker'}
}finally{Pop-Location}
