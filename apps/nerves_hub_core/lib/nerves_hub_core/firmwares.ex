defmodule NervesHubCore.Firmwares do
  import Ecto.Query

  alias NervesHubCore.Accounts.{TenantKey, Tenant}
  alias NervesHubCore.Firmwares.Firmware
  alias NervesHubCore.Devices.Device
  alias NervesHubCore.Deployments.Deployment
  alias NervesHubCore.Products
  alias NervesHubCore.Repo

  @spec get_firmwares_by_product(integer()) :: [Firmware.t()]
  def get_firmwares_by_product(product_id) do
    from(
      f in Firmware,
      where: f.product_id == ^product_id
    )
    |> Firmware.with_product()
    |> Repo.all()
  end

  @spec get_firmware(Tenant.t(), integer()) ::
          {:ok, Firmware.t()}
          | {:error, :not_found}
  def get_firmware(%Tenant{id: tenant_id}, id) do
    from(
      f in Firmware,
      where: f.tenant_id == ^tenant_id,
      where: f.id == ^id
    )
    |> Firmware.with_product()
    |> Repo.one()
    |> case do
      nil -> {:error, :not_found}
      firmware -> {:ok, firmware}
    end
  end

  @spec get_firmware_by_product_and_version(Tenant.t(), String.t(), String.t()) ::
          {:ok, Firmware.t()}
          | {:error, :not_found}
  def get_firmware_by_product_and_version(%Tenant{} = tenant, product, version) do
    Firmware
    |> Repo.get_by(tenant_id: tenant.id, product: product, version: version)
    |> case do
      nil -> {:error, :not_found}
      firmware -> {:ok, firmware}
    end
  end

  @spec get_firmware_by_uuid(Tenant.t(), String.t()) ::
          {:ok, Firmware.t()}
          | {:error, :not_found}
  def get_firmware_by_uuid(%Tenant{} = tenant, uuid) do
    Firmware
    |> Repo.get_by(tenant_id: tenant.id, uuid: uuid)
    |> case do
      nil -> {:error, :not_found}
      firmware -> {:ok, firmware}
    end
  end

  @spec create_firmware(map) ::
          {:ok, Firmware.t()}
          | {:error, Changeset.t()}
  def create_firmware(%{product_name: product_name} = params) when is_binary(product_name) do
    with {:ok, product} <-
           Products.get_product_by_tenant_id_and_name(params.tenant_id, product_name) do
      params
      |> Map.put(:product_id, product.id)
      |> do_create_firmware()
    else
      _ -> do_create_firmware(params)
    end
  end

  def create_firmware(params) do
    do_create_firmware(params)
  end

  defp do_create_firmware(params) do
    %Firmware{}
    |> Firmware.changeset(params)
    |> Repo.insert()
  end

  @spec verify_signature(String.t(), [TenantKey.t()]) ::
          {:ok, TenantKey.t()}
          | {:error, :invalid_signature}
          | {:error, :no_public_keys}
  def verify_signature(_filepath, []), do: {:error, :no_public_keys}

  def verify_signature(filepath, keys) do
    keys
    |> Enum.find(fn key ->
      case System.cmd("fwup", ["--verify", "--public-key", key.key, "-i", filepath]) do
        {_, 0} ->
          true

        _ ->
          false
      end
    end)
    |> case do
      %TenantKey{} = key ->
        {:ok, key}

      nil ->
        {:error, :invalid_signature}
    end
  end

  @spec extract_metadata(String.t()) ::
          {:ok, String.t()}
          | {:error}
  def extract_metadata(filepath) do
    case System.cmd("fwup", ["-m", "-i", filepath]) do
      {metadata, 0} ->
        {:ok, metadata}

      _ ->
        {:error}
    end
  end

  @doc """
  Given a device, look for an active deployment where:
    - The architecture of its associated firmware and device match
    - The platform of its associated firmware and device match
    - The version of the device satisfies the version condition of the deployment (if one exists)
    - The device is assigned all tags in the deployment's "tags" condition
  """
  @spec get_eligible_firmware_update(Device.t(), Version.t()) ::
          {:ok, Firmware.t()} | {:ok, :none}
  def get_eligible_firmware_update(%Device{} = device, %Version{} = version) do
    from(
      d in Deployment,
      where: d.product_id == ^device.product_id,
      where: d.is_active == true,
      join: f in assoc(d, :firmware),
      on: f.architecture == ^device.architecture and f.platform == ^device.platform,
      preload: [firmware: f]
    )
    |> Repo.all()
    |> Enum.find(fn deployment ->
      with v <- deployment.conditions["version"],
           true <- v == "" or Version.match?(version, v),
           true <- Enum.all?(deployment.conditions["tags"], fn tag -> tag in device.tags end) do
        true
      else
        _ ->
          false
      end
    end)
    |> case do
      nil -> {:ok, :none}
      deployment -> {:ok, deployment.firmware}
    end
  end
end