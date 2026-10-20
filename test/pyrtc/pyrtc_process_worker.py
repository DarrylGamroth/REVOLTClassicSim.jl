"""Run pyRTC signal processing and control outside the Julia process."""

from __future__ import annotations

import argparse
import sys
from pathlib import Path
from typing import Optional

import numpy as np


CONTROL_PREFIX = "REVOLT_CLASSIC_PYRTC_WORKER "
CONTROL_MATRIX_NUMPY_RELATIVE_TOLERANCE = 2e-5


def control(message: str) -> None:
    print(CONTROL_PREFIX + message, flush=True)


def python_config(**entries):
    return entries


def shack_hartmann_valid_subapertures() -> np.ndarray:
    count = 8
    radius = count / 2
    centre = (count + 1) / 2
    lenslet_axis = (np.arange(count, dtype=np.float64) + 1 - centre) / radius
    axis_1, axis_2 = np.meshgrid(lenslet_axis, lenslet_axis, indexing="ij")
    valid = axis_1 * axis_1 + axis_2 * axis_2 <= 1
    return np.concatenate((valid, valid), axis=0)


def revolt_classic_valid_subapertures(path: Path) -> np.ndarray:
    values = np.fromfile(path, dtype=np.uint8)
    if values.size != 16 * 16:
        raise ValueError(
            f"REVOLT Classic valid-subaperture file contains {values.size} "
            "entries; expected 256"
        )
    if not np.all((values == 0) | (values == 1)):
        raise ValueError(
            "REVOLT Classic valid-subaperture entries must be zero or one"
        )
    mask = values.astype(bool).reshape((16, 16), order="F")
    if np.count_nonzero(mask) != 188:
        raise ValueError(
            "REVOLT Classic valid-subaperture mask must select 188 lenslets"
        )
    return np.concatenate((mask, mask), axis=0)


def slopes_config(
    system: str,
    temporary_directory: Path,
    valid_subapertures_file: Optional[Path],
):
    if system == "shack_hartmann":
        valid_path = temporary_directory / "valid_subapertures.npy"
        np.save(valid_path, shack_hartmann_valid_subapertures())
        return python_config(
            type="SHWFS",
            signalType="slopes",
            subApSpacing=8,
            subApOffsetX=0,
            subApOffsetY=0,
            imageNoise=0.0,
            contrast=0,
            validSubApsFile=str(valid_path),
        )
    if system == "pyramid":
        return python_config(
            type="PYWFS",
            signalType="slopes",
            imageNoise=0.0,
            centralObscurationRatio=0.0,
            flatNorm=True,
            pupils=["9,9", "27,9", "9,27", "27,27"],
            pupilsRadius=8,
        )
    if system == "revolt_classic":
        if valid_subapertures_file is None:
            raise ValueError(
                "REVOLT Classic requires a valid-subaperture file"
            )
        valid_path = temporary_directory / "valid_subapertures.npy"
        np.save(
            valid_path,
            revolt_classic_valid_subapertures(valid_subapertures_file),
        )
        return python_config(
            type="SHWFS",
            signalType="slopes",
            subApSpacing=22,
            subApOffsetX=0,
            subApOffsetY=0,
            imageNoise=0.0,
            contrast=0,
            validSubApsFile=str(valid_path),
        )
    raise ValueError(f"unsupported system {system!r}")


def close_handle(handle) -> None:
    handle.shm.close()
    if hasattr(handle, "metadataShm"):
        handle.metadataShm.close()


def close_components(slopes, loop) -> None:
    handles = (
        loop.signalShm,
        loop.wfcShm,
        slopes.wfsShm,
        slopes.signal,
        slopes.signal2D,
    )
    for handle in handles:
        try:
            close_handle(handle)
        except Exception:
            pass


def process_signal_order(system: str, signal_size: int) -> Optional[np.ndarray]:
    if system != "revolt_classic":
        return None
    if signal_size % 2 != 0:
        raise ValueError("REVOLT Classic requires paired x/y WFS signals")
    lenslet_count = signal_size // 2
    order = np.empty(signal_size, dtype=np.intp)
    order[0::2] = np.arange(lenslet_count, dtype=np.intp)
    order[1::2] = lenslet_count + np.arange(lenslet_count, dtype=np.intp)
    return order


def compute_signal(slopes, order, ordered_signal) -> None:
    slopes.computeSignal()
    if order is None:
        return
    np.take(
        slopes.signal.read_noblock(SAFE=False),
        order,
        out=ordered_signal,
    )
    slopes.signal.write(ordered_signal)


def configure_control_matrix(
    loop,
    matrix_path: str,
    gain: float,
) -> None:
    matrix = np.fromfile(matrix_path, dtype=np.float32)
    expected = loop.signalSize * loop.numModes
    if matrix.size != expected:
        raise ValueError(
            f"control matrix contains {matrix.size} values; expected {expected}"
        )
    if not np.all(np.isfinite(matrix)):
        raise ValueError("control matrix must contain only finite values")
    if not np.isfinite(gain):
        raise ValueError("control gain must be finite")
    loop.CM[:] = matrix.reshape((loop.numModes, loop.signalSize), order="F")
    loop.numActiveModes = loop.numModes
    loop.setGain(gain)


def configure_loop(
    loop,
    matrix_path: str,
    gain: float,
    control_rcond: float,
) -> None:
    """Retain the historical pyRTC-owned pseudoinverse configuration path."""
    matrix = np.fromfile(matrix_path, dtype=np.float32)
    expected = loop.signalSize * loop.numModes
    if matrix.size != expected:
        raise ValueError(
            f"interaction matrix contains {matrix.size} values; expected {expected}"
        )
    if not np.isfinite(control_rcond) or not 0 <= control_rcond < 1:
        raise ValueError("control rcond must be finite and lie in [0, 1)")
    loop.IM[:] = matrix.reshape((loop.signalSize, loop.numModes), order="F")
    loop.numActiveModes = loop.numModes
    loop.CM[:] = np.linalg.pinv(loop.IM, rcond=control_rcond)
    loop.fIM = np.copy(loop.IM)
    loop.setGain(gain)


def verify_control_matrix(
    loop,
    interaction_path: str,
    control_path: str,
    control_rcond: float,
) -> None:
    """Check a caller-prepared control matrix against NumPy's historic path."""
    expected_size = loop.signalSize * loop.numModes
    interaction = np.fromfile(interaction_path, dtype=np.float32)
    control_matrix = np.fromfile(control_path, dtype=np.float32)
    if interaction.size != expected_size:
        raise ValueError(
            f"interaction matrix contains {interaction.size} values; "
            f"expected {expected_size}"
        )
    if control_matrix.size != expected_size:
        raise ValueError(
            f"control matrix contains {control_matrix.size} values; "
            f"expected {expected_size}"
        )
    if not np.all(np.isfinite(interaction)):
        raise ValueError("interaction matrix must contain only finite values")
    if not np.all(np.isfinite(control_matrix)):
        raise ValueError("control matrix must contain only finite values")
    if not np.isfinite(control_rcond) or not 0 <= control_rcond < 1:
        raise ValueError("control rcond must be finite and lie in [0, 1)")
    interaction = interaction.reshape((loop.signalSize, loop.numModes), order="F")
    control_matrix = control_matrix.reshape(
        (loop.numModes, loop.signalSize), order="F"
    )
    expected = np.linalg.pinv(interaction, rcond=control_rcond)
    difference = control_matrix - expected
    relative_error = np.linalg.norm(difference) / np.linalg.norm(expected)
    if relative_error > CONTROL_MATRIX_NUMPY_RELATIVE_TOLERANCE:
        maximum_absolute_error = np.max(np.abs(difference))
        raise ValueError(
            "prepared control matrix disagrees with NumPy pseudoinverse "
            "beyond the Float32 SVD relative tolerance "
            f"{CONTROL_MATRIX_NUMPY_RELATIVE_TOLERANCE}: "
            f"relative error={relative_error}, "
            f"maximum absolute error={maximum_absolute_error}"
        )


def serve(
    system: str,
    temporary_directory: Path,
    valid_subapertures_file: Optional[Path],
) -> None:
    from pyRTC.Loop import Loop
    from pyRTC.SlopesProcess import SlopesProcess

    slopes = SlopesProcess(
        slopes_config(system, temporary_directory, valid_subapertures_file)
    )
    loop = Loop(python_config(gain=0.4, numDroppedModes=0))
    order = process_signal_order(system, loop.signalSize)
    ordered_signal = (
        None
        if order is None
        else np.empty(loop.signalSize, dtype=slopes.signalDType)
    )
    try:
        control(f"READY {loop.signalSize} {loop.numModes}")
        for line in sys.stdin:
            command = line.strip().split()
            if not command:
                continue
            if command[0] == "PROCESS" and len(command) == 1:
                compute_signal(slopes, order, ordered_signal)
                control("PROCESSED")
            elif command[0] == "SET_REF" and len(command) == 1:
                slopes.setRefSlopes(slopes.signal2D.read_noblock())
                control("REF_SET")
            elif command[0] == "CONFIGURE" and len(command) == 4:
                configure_loop(
                    loop,
                    command[1],
                    float(command[2]),
                    float(command[3]),
                )
                control("CONFIGURED")
            elif command[0] == "VERIFY_CONTROL_MATRIX" and len(command) == 4:
                verify_control_matrix(
                    loop,
                    command[1],
                    command[2],
                    float(command[3]),
                )
                control("CONTROL_MATRIX_VERIFIED")
            elif command[0] == "CONFIGURE_CONTROL_MATRIX" and len(command) == 3:
                configure_control_matrix(
                    loop,
                    command[1],
                    float(command[2]),
                )
                control("CONTROL_MATRIX_CONFIGURED")
            elif command[0] == "FLATTEN" and len(command) == 1:
                loop.flatten()
                control("FLATTENED")
            elif command[0] == "STEP" and len(command) == 1:
                compute_signal(slopes, order, ordered_signal)
                loop.standardIntegrator()
                control("STEPPED")
            elif command[0] == "STOP" and len(command) == 1:
                control("STOPPED")
                return
            else:
                raise ValueError(f"invalid worker command: {line.strip()!r}")
    finally:
        close_components(slopes, loop)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--system",
        required=True,
        choices=("shack_hartmann", "pyramid", "revolt_classic"),
    )
    parser.add_argument("--temporary-directory", required=True)
    parser.add_argument("--valid-subapertures-file")
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    temporary_directory = Path(args.temporary_directory).resolve()
    temporary_directory.mkdir(parents=True, exist_ok=True)
    valid_subapertures_file = (
        None
        if args.valid_subapertures_file is None
        else Path(args.valid_subapertures_file).resolve()
    )
    serve(args.system, temporary_directory, valid_subapertures_file)


if __name__ == "__main__":
    main()
