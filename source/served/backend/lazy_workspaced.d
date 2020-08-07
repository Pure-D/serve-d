module served.backend.lazy_workspaced;

import std.algorithm;
import std.experimental.logger;

import workspaced.api;
import workspaced.backend;

alias LazyLoadHook = void delegate() nothrow;
alias LazyLoadHooks = LazyLoadHook[];

class LazyWorkspaceD : WorkspaceD
{
	static class LazyInstance : WorkspaceD.Instance
	{
		private LazyWorkspaceD backend;
		private LazyLoadHooks[string] lazyLoadCallbacks;
		ComponentFactory[] lazyComponents;

		void onLazyLoad(string component, LazyLoadHook hook)
		{
			foreach (com; instanceComponents)
				if (com.info.name == component)
					return hook();

			lazyLoadCallbacks.require(component) ~= hook;
		}

		override void onBeforeAccessComponent(
				ComponentInfo info) const
		{
			// lots of const-remove-casts because lazy loading should in theory
			// not break anything constness related
			foreach (i, com; lazyComponents)
				if (com.info.name == info.name)
				{
					trace("Lazy loading component ",
							info.name);

					Exception error;
					auto wrap = (cast() com).create(cast() backend,
							cast() this, error);
					if (wrap)
						(cast() this).attachComponent(
								ComponentWrapperInstance(wrap,
								com.info));
					else if (backend.onBindFail)
						backend.onBindFail(cast() this,
								cast() com, error);
					return;
				}

			super.onBeforeAccessComponent(info);
		}

		override bool checkHasComponent(ComponentInfo info) const nothrow
		{
			debug try { trace(__FUNCTION__, ": ", info, " of ", lazyComponents.map!"a.info"); } catch (Exception) {}
			foreach (com; lazyComponents)
				if (com.info.name == info.name)
					return true;

			return super.checkHasComponent(info);
		}

		void attachLazy(ComponentFactory factory)
		{
			lazyComponents ~= factory;
		}

		override bool attach(WorkspaceD workspaced,
				ComponentInfo info)
		{
			foreach (factory; workspaced.components)
			{
				if (factory.info.name == info.name)
				{
					attachLazy(factory);
					return true;
				}
			}
			throw new Exception("Component not found");
		}

		protected override void attachComponent(
				ComponentWrapperInstance component)
		{
			lazyComponents = lazyComponents.remove!(
					a => a.info.name == component.info.name);
			instanceComponents ~= component;

			auto hooks = lazyLoadCallbacks.get(component.info.name, null);
			lazyLoadCallbacks.remove(component.info.name);
			foreach (hook; hooks)
				hook();
		}
	}

	override void onBeforeAccessGlobalComponent(
			ComponentInfo info) const
	{

	}

	override bool checkHasGlobalComponent(ComponentInfo info) const
	{
		return super.checkHasGlobalComponent(info);
	}

	protected override Instance createInstance(
			string cwd, Configuration config)
	{
		auto inst = new LazyInstance();
		inst.cwd = cwd;
		inst.config = config;
		inst.backend = this;
		return inst;
	}

	protected override void autoRegisterComponents(
			Instance inst)
	{
		auto lazyInstance = cast(LazyInstance) inst;
		if (!lazyInstance)
			return super.autoRegisterComponents(inst);

		foreach (factory; components)
		{
			if (factory.autoRegister)
			{
				lazyInstance.attachLazy(factory);
			}
		}
	}

	override void onRegisterComponent(
			ref ComponentFactory factory, bool autoRegister)
	{
		components ~= ComponentFactoryInstance(factory, autoRegister);
		auto info = factory.info;
		Exception error;
		auto glob = factory.create(this, null, error);
		if (glob)
			globalComponents ~= ComponentWrapperInstance(glob, info);
		else if (onBindFail)
			onBindFail(null, factory, error);

		if (autoRegister)
			foreach (ref instance; instances)
			{
				auto lazyInstance = cast(LazyInstance) instance;
				if (lazyInstance)
					lazyInstance.attachLazy(factory);
				else
				{
					auto inst = factory.create(this,
							instance, error);
					if (inst)
						instance.attachComponent(ComponentWrapperInstance(inst,
								factory.info));
					else if (onBindFail)
						onBindFail(instance, factory, error);
				}
			}
	}

	override bool attach(Instance instance,
			string component, out Exception error)
	{
		auto lazyInstance = cast(LazyInstance) instance;
		if (!lazyInstance)
			return super.attach(instance, component, error);

		foreach (factory; components)
		{
			if (factory.info.name == component)
			{
				lazyInstance.attachLazy(factory);
				return true;
			}
		}
		return false;
	}

	bool attachEager(Instance instance,
			string component, out Exception error)
	{
		return super.attach(instance, component, error);
	}
}
